import Foundation

/// **Pure "Yours" model for the Library** (Library redesign L1, prompt 183): every activity you've actually logged —
/// lifts, climbs, runs, timed holds, dance/other — built from session history through `ActivityIdentity`, with
/// usage (sessions all-time + last 90 days, last done), a headline number, and per-discipline sorting/filtering.
/// Foundation only, so the rules are unit-tested without a device; the Library's "Yours" tab and the climbing
/// overview both render it.
enum LibraryCatalog {

    struct Row: Identifiable, Equatable, Sendable {
        struct Climb: Equatable, Sendable {
            let type: ClimbType
            let grade: String?
            /// Best outcome across every attempt in this set (flash > sent > project > attempt).
            let status: KilterAscentStatus?
            let attempts: Int
            let gym: String?
            let wall: String?
            /// When this set of the climb was first logged — "set 14 Sep".
            let setStart: Date
            /// A newer set of the same climb exists (the gym reset it and you logged it again).
            let isReset: Bool
            var sent: Bool { status?.isSend ?? false }
        }

        let key: ActivityKey
        let title: String
        let discipline: WorkoutDiscipline
        let sessions: Int
        /// Distinct active days (5 am → 5 am, so a 1 am festival set belongs to that night) — the default count, and
        /// what "most used" ranks on: several short sessions in one day are one day.
        let days: Int
        let recentDays: Int
        /// Completed efforts: sets for a lift / hold / festival, attempts for a climb, legs for a run.
        let efforts: Int
        /// Sessions in the last 90 days — "most used" ranks on this first.
        let recentSessions: Int
        let lastDate: Date
        /// The number that matters at a glance: "75 kg × 8", "5:33/km", "1:03 · +11 kg".
        let headline: String?
        /// The discipline's "best" value for sorting (e1RM kg · grade difficulty · pace sec/km · hold sec · time sec).
        let bestValue: Double?
        let climb: Climb?
        /// Created in the Library but never logged yet (prompt 186) — shown as "Not done yet".
        var notDoneYet: Bool = false
        /// What you did the most recent time (prompt 187), for the pickers: "4 × 8 @ 75 kg", "1:30", "5 km · 5:33/km".
        var last: String? = nil
        var id: ActivityKey { key }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case mostUsed, recent, best, attempts, name
        var id: String { rawValue }

        func label(for discipline: WorkoutDiscipline?) -> String {
            switch self {
            case .mostUsed: return "Most used"
            case .recent: return "Recently done"
            case .name: return "Name A–Z"
            case .attempts: return "Most attempts"
            case .best:
                switch discipline {
                case .strength?: return "Best e1RM"
                case .climb?: return "Hardest grade"
                case .run?: return "Fastest pace"
                case .timed?: return "Longest hold"
                default: return "Best"
                }
            }
        }
    }

    /// The sorts that make sense for a discipline ("All" mixes units, so it has no "best").
    static func sorts(for discipline: WorkoutDiscipline?) -> [Sort] {
        switch discipline {
        case nil, .dance?, .other?: return [.mostUsed, .recent, .name]
        case .climb?: return [.mostUsed, .recent, .best, .attempts, .name]
        default: return [.mostUsed, .recent, .best, .name]
        }
    }

    enum ClimbFilter: String, CaseIterable, Sendable { case all, projects, sent }

    /// What a row's count means — chosen per discipline in the Library (prompt 183 follow-up). Days by default.
    enum CountUnit: String, CaseIterable, Identifiable, Sendable {
        case days, sessions, efforts
        var id: String { rawValue }

        /// The menu label for a discipline ("Sets" becomes "Attempts" for climbs, "Legs" for runs).
        func label(for discipline: WorkoutDiscipline?) -> String {
            switch self {
            case .days: return "Days"
            case .sessions: return "Sessions"
            case .efforts: return Self.effortNoun(discipline, plural: true).capitalized
            }
        }

        static func effortNoun(_ d: WorkoutDiscipline?, plural: Bool) -> String {
            switch d {
            case .climb?: return plural ? "attempts" : "attempt"
            case .run?: return plural ? "legs" : "leg"
            default: return plural ? "sets" : "set"
            }
        }
    }

    static func count(_ row: Row, _ unit: CountUnit) -> Int {
        switch unit {
        case .days: return row.days
        case .sessions: return row.sessions
        case .efforts: return row.efforts
        }
    }

    /// "3 days", "8 sessions", "32 sets", "17 attempts".
    static func countLabel(_ row: Row, _ unit: CountUnit) -> String {
        let n = count(row, unit)
        switch unit {
        case .days: return "\(n) \(n == 1 ? "day" : "days")"
        case .sessions: return "\(n) \(n == 1 ? "session" : "sessions")"
        case .efforts: return "\(n) \(CountUnit.effortNoun(row.discipline, plural: n != 1))"
        }
    }

    /// The day a session counts toward: the calendar day of `date − 5 h`, so a night out (or a late gym session)
    /// that runs past midnight stays on the day it started.
    static func activeDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-5 * 3600))
    }

    static let recentWindowDays = 90

    // MARK: - Build

    /// Every activity in `history` that has at least one completed effort. `title` resolves a display name for an
    /// entity (the catalog name for a lift, the typed name otherwise); the most recent instance's name wins.
    /// A created activity (prompt 186) to show until you log it: its key (as saved), template and creation date.
    struct CreatedInput: Sendable {
        let key: ActivityKey
        let template: LibraryTemplate
        let createdAt: Date
    }

    static func yours(history: [WorkoutSession], identity: ActivityIdentity, unit: WeightUnit,
                      now: Date = .now, created: [CreatedInput] = [],
                      title: (SessionExercise) -> String) -> [Row] {
        let logged = loggedRows(history: history, identity: identity, unit: unit, now: now, title: title)
        return logged + createdRows(created, logged: logged, unit: unit, title: title)
    }

    /// Created activities that haven't been logged since: a logged row with the same key — or, for a climb, the same
    /// climb (base) logged on/after the creation day — replaces it. A climb's key carries its set day, so logging it
    /// later lands on a different key; the base comparison is what folds the two together.
    private static func createdRows(_ created: [CreatedInput], logged: [Row], unit: WeightUnit,
                                    title: (SessionExercise) -> String) -> [Row] {
        func base(_ k: ActivityKey) -> String { String(k.nameKey.split(separator: "@").first ?? "") }
        let distanceUnit: DistanceUnit = unit == .lb ? .mi : .km
        return created.compactMap { c in
            let replaced = logged.contains { r in
                r.key == c.key || (c.key.exerciseId == ActivityIdentity.climbExerciseId && r.key.exerciseId == c.key.exerciseId
                                   && base(r.key) == base(c.key)
                                   && r.lastDate >= Calendar.current.startOfDay(for: c.createdAt))
            }
            guard !replaced else { return nil }
            let ex = c.template.exercise
            var headline = "Not done yet"
            if let m = c.template.targetDistanceMeters, m > 0 {
                headline = "\(SetMeasure.formatDistance(m, unit: distanceUnit)) · not done yet"
            }
            let climb = ex.discipline == .climb
                ? Row.Climb(type: ex.climbType, grade: ex.climbGradeLabel, status: nil, attempts: 0, gym: ex.gym,
                            wall: ex.wall, setStart: c.createdAt, isReset: false)
                : nil
            return Row(key: c.key, title: title(ex), discipline: ex.discipline, sessions: 0, days: 0, recentDays: 0,
                       efforts: 0, recentSessions: 0, lastDate: c.createdAt, headline: headline, bestValue: nil,
                       climb: climb, notDoneYet: true)
        }
    }

    private static func loggedRows(history: [WorkoutSession], identity: ActivityIdentity, unit: WeightUnit,
                                   now: Date, title: (SessionExercise) -> String) -> [Row] {
        struct Acc {
            var discipline: WorkoutDiscipline
            var title: String
            var sessions = Set<UUID>()
            var recent = Set<UUID>()
            var days = Set<Date>()
            var recentDays = Set<Date>()
            var efforts = 0
            var last = Date.distantPast
            var entities: [SessionExercise] = []
            var latest: SessionExercise
        }
        let recentCutoff = now.addingTimeInterval(-Double(recentWindowDays) * 86_400)
        var acc: [ActivityKey: Acc] = [:]
        for s in history where !s.isActive {
            for ex in s.exercises where ex.sets.contains(where: { $0.completedAt != nil }) {
                guard let key = identity.key(for: ex, loggedAt: s.startedAt) else { continue }
                // A festival's row is named after the festival, not whichever artist was last.
                let name = identity.festivalName[key] ?? title(ex)
                var a = acc[key] ?? Acc(discipline: ex.discipline, title: name, latest: ex)
                a.sessions.insert(s.id)
                let day = activeDay(s.startedAt)
                a.days.insert(day)
                if s.startedAt >= recentCutoff { a.recent.insert(s.id); a.recentDays.insert(day) }
                a.efforts += ex.sets.filter { $0.completedAt != nil }
                    .reduce(0) { $0 + (ex.discipline == .climb ? max(1, $1.climbAttempts ?? 1) : 1) }
                if s.startedAt >= a.last { a.last = s.startedAt; a.title = name; a.latest = ex }
                a.entities.append(ex)
                acc[key] = a
            }
        }

        // Which climb bases have more than one set (→ the older sets are "reset").
        func base(_ key: ActivityKey) -> String { String(key.nameKey.split(separator: "@").first ?? "") }
        var latestSetPerBase: [String: Date] = [:]
        for (key, _) in acc where key.exerciseId == ActivityIdentity.climbExerciseId {
            if let start = identity.setStart[key] {
                latestSetPerBase[base(key)] = max(latestSetPerBase[base(key)] ?? .distantPast, start)
            }
        }

        let distanceUnit: DistanceUnit = unit == .lb ? .mi : .km
        return acc.map { key, a in
            let (headline, best) = headlineAndBest(a.discipline, a.entities, unit: unit, distanceUnit: distanceUnit)
            var climb: Row.Climb?
            if a.discipline == .climb {
                let attempts = a.entities.flatMap(\.sets).filter { $0.completedAt != nil }
                    .reduce(0) { $0 + max(1, $1.climbAttempts ?? 1) }
                let start = identity.setStart[key] ?? a.last
                climb = Row.Climb(type: a.latest.climbType, grade: a.latest.climbGradeLabel,
                                  status: bestStatus(a.entities), attempts: attempts,
                                  gym: a.latest.gym, wall: a.latest.wall, setStart: start,
                                  isReset: (latestSetPerBase[base(key)] ?? start) > start)
            }
            return Row(key: key, title: a.title, discipline: a.discipline, sessions: a.sessions.count,
                       days: a.days.count, recentDays: a.recentDays.count, efforts: a.efforts,
                       recentSessions: a.recent.count, lastDate: a.last, headline: headline,
                       bestValue: best, climb: climb,
                       last: lastLine(a.latest, unit: unit, distanceUnit: distanceUnit))
        }
    }

    /// A display name for an entity when no catalog resolver applies: the typed name, or — for an unnamed climb —
    /// its grade, colour and wall ("V4 Yellow · Cave wall"), or the de-slugged id.
    static func fallbackTitle(_ ex: SessionExercise) -> String {
        if let n = ex.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        if ex.discipline == .climb {
            let first = [ex.climbGradeLabel, ex.climbColor?.label].compactMap { $0 }.joined(separator: " ")
            let parts = [first.isEmpty ? ex.climbType.label : first, ex.wall].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.joined(separator: " · ")
        }
        return ex.exerciseId.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Sort / filter

    static func sorted(_ rows: [Row], by sort: Sort) -> [Row] {
        rows.sorted { a, b in
            switch sort {
            case .mostUsed:
                // Days, not sessions: ending a festival night after every set (or splitting a gym day) mustn't
                // make something look more used than it is.
                if a.recentDays != b.recentDays { return a.recentDays > b.recentDays }
                if a.days != b.days { return a.days > b.days }
                return a.lastDate > b.lastDate
            case .recent:
                // Same session → the one you do more often first.
                if a.lastDate != b.lastDate { return a.lastDate > b.lastDate }
                return a.days != b.days ? a.days > b.days
                                                : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .name:
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .attempts:
                let x = a.climb?.attempts ?? 0, y = b.climb?.attempts ?? 0
                return x != y ? x > y : a.lastDate > b.lastDate
            case .best:
                // A missing value sorts last; pace is the one lower-is-better metric.
                switch (a.bestValue, b.bestValue) {
                case let (x?, y?) where x != y:
                    return a.discipline == .run ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.lastDate > b.lastDate
                }
            }
        }
    }

    static func filter(_ rows: [Row], query: String, discipline: WorkoutDiscipline?,
                       climbFilter: ClimbFilter = .all) -> [Row] {
        let tokens = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { r in
            if let discipline, r.discipline != discipline { return false }
            if let c = r.climb {
                if climbFilter == .projects && c.sent { return false }
                if climbFilter == .sent && !c.sent { return false }
            } else if climbFilter != .all { return false }
            guard !tokens.isEmpty else { return true }
            let hay = [r.title, r.headline ?? "", r.climb?.grade ?? "", r.climb?.gym ?? "", r.climb?.wall ?? ""]
                .joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    // MARK: - Headline

    private static func headlineAndBest(_ d: WorkoutDiscipline, _ ents: [SessionExercise], unit: WeightUnit,
                                        distanceUnit: DistanceUnit) -> (String?, Double?) {
        let done = ents.flatMap { ex in ex.sets.filter { $0.completedAt != nil } }
        switch d {
        case .strength:
            // Best set by e1RM; bodyweight-only → most reps.
            var best: (e1rm: Double, kg: Double, reps: Int)?
            for s in done {
                guard let r = s.actualReps, r > 0, let w = s.actualWeight, w > 0 else { continue }
                let kg = WorkoutMath.toKg(w, s.weightUnit)
                let e = ActivityDashboard.oneRepMax(kg: kg, reps: r)
                if e > (best?.e1rm ?? 0) { best = (e, kg, r) }
            }
            if let b = best { return ("\(ActivityDashboard.weightLabel(kg: b.kg, unit: unit)) × \(b.reps)", b.e1rm) }
            if let reps = done.compactMap(\.actualReps).max(), reps > 0 { return ("\(reps) reps", nil) }
            return (nil, nil)
        case .climb:
            let latest = ents.last
            let grade = latest?.climbGradeLabel
            let difficulty = grade.flatMap { g in latest?.climbGradeScale.difficulty(for: g) }
            return (grade, difficulty)
        case .run:
            let paces = ents.compactMap(RunStats.avgPaceSecPerKm)
            guard let p = paces.min() else { return (nil, nil) }
            return (SetMeasure.formatPace(secPerKm: p, unit: distanceUnit), p)
        case .timed:
            guard let hold = done.compactMap(\.durationSec).filter({ $0 > 0 }).max() else { return (nil, nil) }
            var text = SetMeasure.formatDuration(hold)
            if let load = done.compactMap(\.loadKg).max(), load > 0 { text += " · +\(SetMeasure.formatWeight(load)) kg" }
            return (text, hold)
        case .dance, .other:
            let t = done.compactMap(\.durationSec).reduce(0, +)
            return t > 0 ? (SetMeasure.formatDuration(t), t) : (nil, nil)
        }
    }

    /// The most recent instance in a few words (prompt 187) — the pickers' "Last: …" line. Strength: sets × top reps
    /// @ top weight; climb: grade · attempts; hold: longest; run: distance · pace; dance/other: time. `nil` when the
    /// entity has nothing completed to describe.
    static func lastLine(_ ex: SessionExercise, unit: WeightUnit, distanceUnit: DistanceUnit) -> String? {
        let done = ex.sets.filter { $0.completedAt != nil }
        guard !done.isEmpty else { return nil }
        switch ex.discipline {
        case .strength:
            let reps = done.compactMap(\.actualReps).max()
            let top = done.compactMap { s in s.actualWeight.flatMap { $0 > 0 ? WorkoutMath.toKg($0, s.weightUnit) : nil } }.max()
            var text = "\(done.count) × \(reps.map(String.init) ?? "–")"
            if let top { text += " @ \(ActivityDashboard.weightLabel(kg: top, unit: unit))" }
            return text
        case .climb:
            let attempts = done.reduce(0) { $0 + max(1, $1.climbAttempts ?? 1) }
            return [ex.climbGradeLabel, "\(attempts) \(attempts == 1 ? "attempt" : "attempts")"]
                .compactMap { $0 }.joined(separator: " · ")
        case .timed:
            guard let hold = done.compactMap(\.durationSec).filter({ $0 > 0 }).max() else { return "\(done.count) sets" }
            return done.count > 1 ? "\(done.count) × \(SetMeasure.formatDuration(hold))" : SetMeasure.formatDuration(hold)
        case .run:
            let meters = done.compactMap(\.distanceMeters).reduce(0, +)
            var parts: [String] = []
            if meters > 0 { parts.append(SetMeasure.formatDistance(meters, unit: distanceUnit)) }
            if let p = RunStats.avgPaceSecPerKm(ex) { parts.append(SetMeasure.formatPace(secPerKm: p, unit: distanceUnit)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .dance, .other:
            let t = done.compactMap(\.durationSec).reduce(0, +)
            return t > 0 ? SetMeasure.formatDuration(t) : nil
        }
    }

    private static func bestStatus(_ ents: [SessionExercise]) -> KilterAscentStatus? {
        let rank: (KilterAscentStatus) -> Int = {
            switch $0 { case .flash: return 3; case .sent: return 2; case .project: return 1; case .attempt: return 0 }
        }
        return ents.compactMap(\.resolvedClimbStatus).max { rank($0) < rank($1) }
    }
}
