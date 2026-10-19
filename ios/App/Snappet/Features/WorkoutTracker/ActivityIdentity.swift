import Foundation

/// **Pure, history-aware activity identity** (Library redesign L1, prompt 183) — the ONE answer to "is this the same
/// activity as that?" for the Library, past clips, dashboards and insights.
///
/// - Non-climbs: `ActivityKey.plain` (catalog `exerciseId`, or `adhoc-*` + normalized name).
/// - **Climbs** have no stored identity, and gyms RESET their climbs every few weeks, so a climb is
///   **its base identity + its set window**:
///   - base = normalized name + gym when it has a name; otherwise grade + gym + wall + colour (so "V4 yellow, Cave
///     wall" is a climb too). A bare grade with nothing else to pin it has NO identity — every V4 isn't one climb.
///   - set window: logs of the same base stay ONE climb while no gap between consecutive logs exceeds `resetDays`
///     (default 28, the user's "gyms reset every 3–4 weeks"); a longer gap starts a NEW climb, keyed by the day it
///     was first logged. So a project worked across three sessions stays one climb, and the same name a month
///     later is a different one.
///   - The library id (`climb.boulder`, `adhoc-climbAttempt`) is NOT part of it: the same climb logged from the
///     Library or from "Add a climb" is still the same climb.
/// - **Festival sets** (`festival-set` — one dance entity per artist set) are one activity PER FESTIVAL, named after
///   it (the night's session carries the festival's name). A set is a one-off performance, so grouping by artist
///   would be meaningless, and grouping every festival together (the shared id) mislabelled the row with whichever
///   artist was last.
struct ActivityIdentity: Sendable {
    static let defaultResetDays = 28
    /// The user's "climbs reset after" setting (Workout Settings, prompt 185); `defaultResetDays` until they choose.
    static let resetDaysKey = "library.climbResetDays"
    static var configuredResetDays: Int {
        let v = UserDefaults.standard.integer(forKey: resetDaysKey)
        return v > 0 ? v : defaultResetDays
    }

    let resetDays: Int
    /// Every climb entity in the given sessions → its key.
    private var climbKeys: [UUID: ActivityKey] = [:]
    /// Per base: its sets in time order (first log, last log) — for keys of entities not in the sessions (a climb
    /// just added to the live session).
    private var setsByBase: [String: [(start: Date, last: Date)]] = [:]
    /// Each climb key's set start, for "set 14 Sep" labels.
    private(set) var setStart: [ActivityKey: Date] = [:]
    /// Festival-set entities → their festival's key, and each festival key's display name (as the Festival app has it).
    private var festivalKeys: [UUID: ActivityKey] = [:]
    private(set) var festivalName: [ActivityKey: String] = [:]

    init(sessions: [WorkoutSession], resetDays: Int = ActivityIdentity.configuredResetDays) {
        self.resetDays = max(1, resetDays)
        let window = Double(self.resetDays) * 86_400
        var logs: [(base: String, id: UUID, date: Date)] = []
        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for ex in s.exercises where ex.exerciseId == Self.festivalExerciseId {
                let key = ActivityKey(exerciseId: Self.festivalExerciseId, nameKey: ActivityKey.normalize(s.routineName))
                festivalKeys[ex.id] = key
                festivalName[key] = s.routineName.isEmpty ? "Festival" : s.routineName   // latest spelling wins
            }
            for ex in s.exercises where ex.discipline == .climb && ex.exerciseId != Self.festivalExerciseId {
                if let base = Self.climbBase(ex) { logs.append((base, ex.id, s.startedAt)) }
            }
        }
        for (base, group) in Dictionary(grouping: logs, by: \.base) {
            var sets: [(start: Date, last: Date)] = []
            for log in group.sorted(by: { $0.date < $1.date }) {
                if let current = sets.last, log.date.timeIntervalSince(current.last) <= window {
                    sets[sets.count - 1].last = log.date
                } else {
                    sets.append((log.date, log.date))
                }
                let key = Self.climbKey(base: base, setStart: sets[sets.count - 1].start)
                climbKeys[log.id] = key
                setStart[key] = sets[sets.count - 1].start
            }
            setsByBase[base] = sets
        }
    }

    /// The activity a session entity belongs to (`nil` = no cross-session identity). An entity that wasn't in the
    /// sessions this identity was built from (a climb added to the live session since) is placed as if logged at
    /// `loggedAt`: into the latest set of its base when that set is still within the reset window, else a new one.
    func key(for ex: SessionExercise, loggedAt: Date = .now) -> ActivityKey? {
        if ex.exerciseId == Self.festivalExerciseId { return festivalKeys[ex.id] }
        // A board climb seen as activity history (prompt 189) is its Kilter climb, whatever its angle or date.
        if let uuid = KilterActivityHistory.climbUUID(ex) {
            return ActivityKey(exerciseId: LibraryCatalog.kilterExerciseId, nameKey: uuid)
        }
        guard ex.discipline == .climb else { return ActivityKey.plain(ex) }
        if let known = climbKeys[ex.id] { return known }
        guard let base = Self.climbBase(ex) else { return nil }
        if let latest = setsByBase[base]?.last,
           loggedAt.timeIntervalSince(latest.last) <= Double(resetDays) * 86_400 {
            return Self.climbKey(base: base, setStart: latest.start)
        }
        return Self.climbKey(base: base, setStart: loggedAt)
    }

    /// Whether a session entity belongs to `key` (a whole-discipline key matches every entity of it).
    func matches(_ key: ActivityKey, _ ex: SessionExercise) -> Bool {
        if let d = key.disciplineScope { return ex.discipline == d }
        return self.key(for: ex) == key
    }

    // MARK: - Climb identity

    static func climbBase(_ ex: SessionExercise) -> String? {
        let name = ActivityKey.normalize(ex.displayName ?? "")
        let gym = ActivityKey.normalize(ex.gym ?? "")
        if !name.isEmpty { return "n:\(name)|\(gym)" }
        let wall = ActivityKey.normalize(ex.wall ?? "")
        let colour = ex.climbColorRaw ?? ""
        guard !(gym.isEmpty && wall.isEmpty && colour.isEmpty) else { return nil }
        let grade = ActivityKey.normalize(ex.climbGradeLabel ?? "")
        return "u:\(grade)|\(gym)|\(wall)|\(colour)"
    }

    static let climbExerciseId = "climb"
    /// The id every festival set is logged under (`FestivalScheduleView.appendDanceExercise`).
    static let festivalExerciseId = "festival-set"

    private static func climbKey(base: String, setStart: Date) -> ActivityKey {
        ActivityKey(exerciseId: climbExerciseId, nameKey: "\(base)@\(dayString(setStart))")
    }

    private static func dayString(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
