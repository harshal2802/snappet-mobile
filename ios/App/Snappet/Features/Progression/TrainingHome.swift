import Foundation

/// The pure parts of the training-first Home (prompt 150; wireframe `docs/ux-research/progression/home.html`):
/// what today's session is likely worth, XP per day this week, recent wins, what's coming up, and a
/// kind note after a missed planned day.
@MainActor
enum TrainingHome {

    // MARK: - Today's session: likely XP and minutes

    /// About what a session of this routine earns: the average of its last three awards (rounded to 5),
    /// or finish + 45 minutes + on plan for a routine never done.
    static func xpEstimate(routineID: UUID, sessions: [WorkoutSession], ledger: Progression.Ledger) -> Int {
        let recent = sessions.filter { $0.routineID == routineID }
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { ledger.awards[$0.id]?.total }
            .prefix(3)
        let raw = recent.isEmpty
            ? Progression.Rules.finish + 45 * Progression.Rules.perMinute + Progression.Rules.onPlan
            : recent.reduce(0, +) / recent.count
        return Int((Double(raw) / 5).rounded()) * 5
    }

    /// Typical length of this routine in minutes (average of the last three), nil if never done.
    static func typicalMinutes(routineID: UUID, sessions: [WorkoutSession]) -> Int? {
        let recent = sessions.filter { $0.routineID == routineID && $0.completedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }.prefix(3)
        guard !recent.isEmpty else { return nil }
        return Int((recent.map(\.duration).reduce(0, +) / Double(recent.count) / 60).rounded())
    }

    // MARK: - This week

    struct Day: Equatable, Sendable {
        var day: DayKey
        var isToday: Bool
        var xp: Int
        var state: RoutineReminderPlanner.WeekDay.State
    }

    /// The seven days of this week with the XP earned each day and the plan state.
    static func week(sessions: [WorkoutSession], ledger: Progression.Ledger, plan: [RoutineReminderPlanner.WeekDay],
                     now: Date, calendar: Calendar = .current) -> [Day] {
        var xpByDay: [DayKey: Int] = [:]
        for s in sessions { if let a = ledger.awards[s.id] { xpByDay[DayKey(s.startedAt, calendar: calendar), default: 0] += a.total } }
        let today = DayKey(now, calendar: calendar)
        let start = DayKey(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now, calendar: calendar)
        return (0..<7).map { i in
            let d = start.adding(days: i, calendar: calendar)
            return Day(day: d, isToday: d == today, xp: xpByDay[d] ?? 0,
                       state: plan.first { $0.day == d }?.state ?? .none)
        }
    }

    // MARK: - Recent wins

    struct Win: Equatable, Sendable, Identifiable {
        var id: String { "\(sessionID)-\(title)" }
        var sessionID: UUID
        var icon: String
        var title: String
        var detail: String
    }

    /// Records, first sends and count milestones from the last `days` days, newest first.
    static func recentWins(_ sessions: [WorkoutSession], now: Date, days: Int = 14, limit: Int = 6,
                           calendar: Calendar = .current) -> [Win] {
        let done = sessions.filter { $0.completedAt != nil && !$0.isImportedFromHealth }
        guard let since = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        var out: [Win] = []
        for s in done.filter({ $0.startedAt >= since }).sorted(by: { $0.startedAt > $1.startedAt }) {
            let when = s.startedAt.formatted(.dateTime.weekday(.abbreviated))
            let series = SessionInsights.comparable(for: s, in: done)
            for b in SessionInsights.badges(s, prior: series, allHistory: done, resolve: Progression.exerciseName,
                                            unit: .kg, includeStreak: false) {
                if case .sessionCount(let n, let name) = b {
                    out.append(Win(sessionID: s.id, icon: "🎯", title: "\(SessionInsights.ordinal(n)) \(name)", detail: when))
                } else if let label = Progression.recordLabel(b) {
                    let icon: String = if case .firstSend = b { "🎉" } else if case .peakForcePR = b { "⚡️" } else { "🏆" }
                    out.append(Win(sessionID: s.id, icon: icon, title: label, detail: "\(s.routineName) · \(when)"))
                }
            }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    // MARK: - Coming up

    struct Growth: Equatable, Sendable {
        var next: BuddyStage
        var atLevel: Int
        var levelsToGo: Int
        /// Progress from this stage's first level to the next stage's.
        var fraction: Double
    }

    static func nextGrowth(_ level: Progression.LevelInfo) -> Growth? {
        guard let at = Progression.nextStageLevel(after: level.level) else { return nil }
        let from = [1, 2, 5, 10, 20].last { $0 <= level.level } ?? 1
        let fraction = (Double(level.level - from) + level.fraction) / Double(max(1, at - from))
        return Growth(next: Progression.stage(forLevel: at), atLevel: at, levelsToGo: at - level.level,
                      fraction: min(1, fraction))
    }

    struct Milestone: Equatable, Sendable {
        var name: String
        var target: Int
        var count: Int
        var toGo: Int { target - count }
        var fraction: Double
    }

    /// The routine (or quick-session series) closest to its next count milestone.
    static func nextMilestone(_ sessions: [WorkoutSession]) -> Milestone? {
        let done = sessions.filter { $0.completedAt != nil && !$0.isImportedFromHealth }
        let groups = Dictionary(grouping: done) { $0.routineID?.uuidString ?? "q:" + $0.routineName }
        return groups.values.compactMap { list -> Milestone? in
            guard let name = list.first?.routineName, list.count >= 2 else { return nil }
            let m = SessionInsights.nextMilestone(count: list.count)
            let span = Double(max(1, m.target - m.previous))
            return Milestone(name: name, target: m.target, count: list.count,
                             fraction: Double(list.count - m.previous) / span)
        }
        .min { ($0.toGo, -$0.count) < ($1.toGo, -$1.count) }
    }

    // MARK: - A kind note after a miss

    /// "You missed Thursday's Push Day" — the latest missed planned day this week (nil when paused).
    static func missedNote(plan: [RoutineReminderPlanner.WeekDay], paused: Bool, calendar: Calendar = .current) -> String? {
        guard !paused, let miss = plan.last(where: { $0.state == .missed }), let name = miss.names.first else { return nil }
        let day = miss.day.date(calendar: calendar).formatted(.dateTime.weekday(.wide))
        return "You missed \(day)'s \(name). One session today gets your Form back up — nothing is lost."
    }
}
