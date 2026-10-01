import Foundation

// Progression P2 (prompt 149): pause mode and streak freezes. Pauses are the only stored state (a small
// JSON list in BuddyDefaults); streaks and freezes are derived from history + pauses like everything else.

extension Progression {

    /// A rest week, injury, trip or illness. Form and the week streak are held while it covers a day;
    /// training anyway still earns XP.
    struct Pause: Codable, Hashable, Sendable, Identifiable {
        enum Reason: String, Codable, CaseIterable, Sendable, Identifiable {
            case rest, injury, travel, sick
            var id: String { rawValue }
            var title: String {
                switch self {
                case .rest: "Rest week"
                case .injury: "Injury"
                case .travel: "Travel"
                case .sick: "Sick"
                }
            }
        }

        var id = UUID()
        var reason: Reason
        var start: Date
        /// Planned end; nil = until you say you're back.
        var plannedEnd: Date?
        /// When it was actually ended (early, or on return).
        var endedAt: Date?
        var muteReminders: Bool

        var end: Date { endedAt ?? plannedEnd ?? .distantFuture }
        func isActive(at now: Date) -> Bool { start <= now && now < end }
        func covers(_ d: Date) -> Bool { start <= d && d < end }
        func overlaps(_ a: Date, _ b: Date) -> Bool { start < b && a < end }
    }

    static func activePause(_ pauses: [Pause], now: Date = .now) -> Pause? {
        pauses.first { $0.isActive(at: now) }
    }

    // MARK: - Week streak with freezes

    struct StreakState: Equatable, Sendable {
        /// Consecutive weeks trained (frozen and paused weeks keep it alive without adding to it).
        var weeks: Int
        /// Freezes saved up (earned one per 4 streak weeks, at most 2).
        var freezes: Int
        /// Week starts a freeze was spent on, oldest first.
        var frozenWeeks: [Date]
        /// Streak weeks until the next freeze is earned.
        var nextFreezeIn: Int { 4 - weeks % 4 }

        static let zero = StreakState(weeks: 0, freezes: 0, frozenWeeks: [])
    }

    enum Streaks {
        static let freezeEvery = 4
        static let maxFreezes = 2
    }

    /// Walk week by week from the first trained week through `endWeek`: a trained week adds to the
    /// streak (every 4th earns a freeze, up to 2); a week overlapping a pause is held; `inProgress` (this
    /// week, not over yet) can't break it; any other missed week spends a freeze, or resets the streak.
    nonisolated static func streak(trainedWeeks: Set<Date>, pauses: [Pause], through endWeek: Date, inProgress: Date?,
                       calendar: Calendar = .current) -> StreakState {
        func week(_ d: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d }
        guard var w = trainedWeeks.min() else { return .zero }
        var state = StreakState.zero
        while w <= endWeek {
            let next = week(calendar.date(byAdding: .day, value: 8, to: w) ?? w)
            if trainedWeeks.contains(w) {
                state.weeks += 1
                if state.weeks % Streaks.freezeEvery == 0 { state.freezes = min(Streaks.maxFreezes, state.freezes + 1) }
            } else if pauses.contains(where: { $0.overlaps(w, next) }) || w == inProgress {
                // held
            } else if state.weeks > 0 && state.freezes > 0 {
                state.freezes -= 1
                state.frozenWeeks.append(w)
            } else {
                state.weeks = 0
            }
            guard next > w else { break }
            w = next
        }
        return state
    }

    /// The overall training streak right now (any session counts).
    static func streak(_ sessions: [WorkoutSession], pauses: [Pause], now: Date = .now,
                       calendar: Calendar = .current) -> StreakState {
        func week(_ d: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d }
        let weeks = Set(sessions.filter { $0.completedAt != nil }.map { week($0.startedAt) })
        let thisWeek = week(now)
        return streak(trainedWeeks: weeks, pauses: pauses, through: thisWeek, inProgress: thisWeek, calendar: calendar)
    }
}

/// The saved pauses (BuddyDefaults — the UI-test scratch suite under tests).
@MainActor
enum PauseStore {
    static let key = "buddy.pauses"

    static func decode(_ raw: String) -> [Progression.Pause] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([Progression.Pause].self, from: data) else { return [] }
        return list
    }

    static func encode(_ pauses: [Progression.Pause]) -> String {
        (try? JSONEncoder().encode(pauses)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func load() -> [Progression.Pause] { decode(BuddyDefaults.store.string(forKey: key) ?? "[]") }

    static func save(_ pauses: [Progression.Pause]) {
        BuddyDefaults.store.set(encode(pauses), forKey: key)
    }

    /// Start a pause now for `weeks` (nil = until back). Ends any pause already running.
    static func start(reason: Progression.Pause.Reason, weeks: Int?, muteReminders: Bool, now: Date = .now) {
        var list = load().map { p -> Progression.Pause in
            var p = p
            if p.isActive(at: now) { p.endedAt = now }
            return p
        }
        let end = weeks.flatMap { Calendar.current.date(byAdding: .day, value: $0 * 7, to: now) }
        list.append(.init(reason: reason, start: now, plannedEnd: end, muteReminders: muteReminders))
        save(list)
    }

    static func endActive(now: Date = .now) {
        save(load().map { p in
            var p = p
            if p.isActive(at: now) { p.endedAt = now }
            return p
        })
    }
}
