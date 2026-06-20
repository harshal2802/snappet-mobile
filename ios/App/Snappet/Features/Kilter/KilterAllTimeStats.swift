import Foundation

/// A plain-value view of one Kilter board **session**, so the all-time aggregator can count distinct
/// sessions (and read their angles) **without** touching the SwiftData `KilterSession` @Model. Views
/// build these with `KilterSessionSummary.from(_:)`; tests synthesize them directly.
struct KilterSessionSummary: Sendable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var angle: Int

    /// Map a SwiftData `KilterSession` to the plain-value summary used by `KilterAllTimeStats`.
    static func from(_ session: KilterSession) -> KilterSessionSummary {
        KilterSessionSummary(id: session.id, startedAt: session.startedAt,
                             endedAt: session.endedAt, angle: session.angle)
    }
}

/// Pure, device-free **all-time** statistics over a climber's full Kilter-board log — the aggregate
/// analogue of the per-session `KilterSessionStats`. It lifts the all-time math (today hand-rolled inline
/// in `KilterHistoryView`) into one tested value type so the dashboard (P3) and history roll-ups / adaptive
/// cards (P4) consume tested aggregates instead of re-deriving math in the view.
///
/// Foundation-only: NO SwiftUI / SwiftData / UIKit. Operates on plain `[KilterClimbLog]` (built via
/// `KilterClimbLog.from`) and optional `[KilterSessionSummary]` (via `KilterSessionSummary.from`).
/// **Kilter-board data only** (no Quick-Session fold-in). Deterministic for a given input.
struct KilterAllTimeStats: Sendable, Equatable {

    // MARK: - Volume & counts

    /// Sends across the whole log (sent + flash).
    var totalSends: Int
    /// Sum of every climb's `attempts` (each climb counts at least one try) — total "effort".
    var totalAttempts: Int
    /// Every logged row (sends + projects + attempts).
    var totalClimbsLogged: Int
    /// Distinct climbs (by `climbUUID`) ever logged.
    var distinctClimbs: Int

    // MARK: - Quality ratios (0…1)

    /// `totalSends / totalClimbsLogged` — share of logged climbs that were sent. 0 on an empty log.
    var sendRate: Double
    /// `flashes / totalSends` — share of sends that were first-try flashes. 0 when nothing was sent.
    var flashRate: Double
    /// Average `attempts` among **sent** climbs (the "attempts-to-send" velocity). `nil` with no sends.
    var attemptsToSend: Double?

    // MARK: - Grade ceiling & trend

    /// Hardest **send** by float difficulty, ever, with its grade label — `nil` when nothing was sent.
    var maxGradeDifficulty: Double?
    var maxGradeLabel: String?
    /// The windowed "Climbing Level" seed — the working grade from `KilterRecommender.workingDifficulty`
    /// over the recent window (`climbingLevelWindow` most recent sends), with its representative label.
    /// `nil` until there are sends.
    ///
    /// - Important: This is a **rounded working-grade bucket** (the recommender's `workingDifficulty`,
    ///   i.e. the hardest difficulty bucket sent enough times), NOT the **raw** `maxGradeDifficulty`
    ///   all-time ceiling. The two are different metrics on a different numeric axis — `maxGradeDifficulty`
    ///   is an exact float peak, this is a bucketed, recency-weighted level — so callers must not compare
    ///   or interchange them as if they shared one scale.
    var climbingLevelDifficulty: Double?
    var climbingLevelLabel: String?
    /// Best send difficulty + label per calendar month, chronological — the max-grade progression series.
    var maxGradeProgression: [GradePoint]

    // MARK: - Time-series

    /// Sends per ISO week for the last `weeklyVolumeWindow` weeks (oldest→newest, including zero weeks).
    var sendsPerWeek: [VolumeBucket]
    /// Sends & attempts per board angle, sorted by angle ascending.
    var angleDistribution: [AngleCount]

    // MARK: - Segmented pyramid (reuses the per-session GradeCount)

    /// All-time grade pyramid, easiest→hardest, with flash/send/project/attempt segmentation per grade.
    var pyramid: [KilterSessionStats.GradeCount]

    // MARK: - Period roll-ups

    /// Per calendar-month roll-ups (chronological): sessions, sends, hardest grade label.
    var monthRollups: [PeriodRollup]
    /// Per ISO-week roll-ups (chronological): sessions, sends, hardest grade label.
    var weekRollups: [PeriodRollup]

    // MARK: - Nested value types

    /// A point on the max-grade progression / a labeled difficulty for a period.
    struct GradePoint: Sendable, Equatable, Identifiable {
        /// Period label (e.g. `"2026-06"`), the stable id.
        var periodLabel: String
        var difficulty: Double
        var gradeLabel: String
        var id: String { periodLabel }
    }

    /// A volume bucket — a count of sends in a labeled time window.
    struct VolumeBucket: Sendable, Equatable, Identifiable {
        /// Window label (e.g. ISO `"2026-W24"`), the stable id.
        var periodLabel: String
        /// The window's start (so a chart can place it on a real axis).
        var start: Date
        var sends: Int
        var id: String { periodLabel }
    }

    /// Sends & attempts at one board angle.
    struct AngleCount: Sendable, Equatable, Identifiable {
        var angle: Int
        var sends: Int
        var attempts: Int
        var id: Int { angle }
    }

    /// A per-period roll-up for the history list / adaptive cards.
    struct PeriodRollup: Sendable, Equatable, Identifiable {
        /// Period label (`"2026-06"` for months, `"2026-W24"` for weeks), the stable id.
        var periodLabel: String
        var sessions: Int
        var sends: Int
        /// Hardest **send** grade label in the period — `nil` when nothing was sent that period.
        var hardestGradeLabel: String?
        var id: String { periodLabel }
    }

    /// An all-zero / empty value — the cold-start state (no logs yet).
    static let empty = KilterAllTimeStats(
        totalSends: 0, totalAttempts: 0, totalClimbsLogged: 0, distinctClimbs: 0,
        sendRate: 0, flashRate: 0, attemptsToSend: nil,
        maxGradeDifficulty: nil, maxGradeLabel: nil,
        climbingLevelDifficulty: nil, climbingLevelLabel: nil, maxGradeProgression: [],
        sendsPerWeek: [], angleDistribution: [], pyramid: [],
        monthRollups: [], weekRollups: [])

    /// Aggregate the full climbing log into all-time stats.
    ///
    /// - `logs`: every logged climb (built via `KilterClimbLog.from`).
    /// - `sessions`: the persisted board sessions; when supplied, roll-up "sessions" counts come from here
    ///   (one session per period it started in). When empty, sessions are counted from the distinct
    ///   `sessionId` among the logs in that period (ad-hoc logs with no `sessionId` don't count).
    /// - `now`: the clock (the weekly-volume window ends here).
    /// - `calendar`: the calendar for month/week bucketing (defaults to `.current`).
    /// - `climbingLevelWindow`: how many of the most recent sends seed the Climbing Level.
    /// - `weeklyVolumeWindow`: how many trailing weeks of send volume to emit.
    static func make(logs: [KilterClimbLog],
                     sessions: [KilterSessionSummary] = [],
                     now: Date,
                     calendar: Calendar = .current,
                     climbingLevelWindow: Int = 20,
                     weeklyVolumeWindow: Int = 8) -> KilterAllTimeStats {
        guard !logs.isEmpty else { return .empty }

        let sorted = logs.sorted { $0.loggedAt < $1.loggedAt }
        // Sends in recency order with a STABLE tie-break (climbUUID, then difficulty) so the
        // `suffix(N)` recency window is deterministic even when many sends share an identical
        // `loggedAt` — common for backfilled / midnight-stamped sessions.
        let sendLogs = sorted.filter(\.isSend).sorted { lhs, rhs in
            if lhs.loggedAt != rhs.loggedAt { return lhs.loggedAt < rhs.loggedAt }
            if lhs.climbUUID != rhs.climbUUID { return lhs.climbUUID < rhs.climbUUID }
            return lhs.difficulty < rhs.difficulty
        }

        let totalSends = sendLogs.count
        let totalAttempts = sorted.reduce(0) { $0 + max(1, $1.attempts) }
        let totalClimbsLogged = sorted.count
        let distinctClimbs = Set(sorted.map(\.climbUUID)).count
        let flashes = sorted.filter { $0.status == .flash }.count

        let sendRate = totalClimbsLogged > 0 ? Double(totalSends) / Double(totalClimbsLogged) : 0
        let flashRate = totalSends > 0 ? Double(flashes) / Double(totalSends) : 0
        let attemptsToSend: Double? = sendLogs.isEmpty
            ? nil
            : Double(sendLogs.reduce(0) { $0 + max(1, $1.attempts) }) / Double(sendLogs.count)

        // Grade ceiling: hardest send ever.
        let hardest = sendLogs.max { $0.difficulty < $1.difficulty }

        // Climbing Level: the working grade over the most recent N sends (recency window), so an old PR
        // doesn't peg the level forever. Reuses the recommender's bucketed working-grade logic verbatim.
        let recentSends = Array(sendLogs.suffix(max(1, climbingLevelWindow)))
        let climbingLevelDiff = KilterRecommender.workingDifficulty(history: recentSends)
        // Pick a representative label for the level deterministically. `workingDifficulty` returns a
        // ROUNDED working-grade bucket, so prefer a send whose `difficulty.rounded()` lands in that
        // bucket; on ties prefer the higher difficulty, then the lexically smaller `gradeLabel`. Fall
        // back to the send nearest the level by absolute distance (same tie-break) when none round into
        // the bucket. No oldest-/first-wins ambiguity for backfilled, equal-timestamp sends.
        let climbingLevelLabel: String? = climbingLevelDiff.flatMap { lvl -> String? in
            // Higher difficulty wins; on equal difficulty the lexically smaller label wins.
            func better(_ a: KilterClimbLog, than b: KilterClimbLog) -> Bool {
                if a.difficulty != b.difficulty { return a.difficulty > b.difficulty }
                return a.gradeLabel < b.gradeLabel
            }
            let inBucket = recentSends.filter { $0.difficulty.rounded() == lvl.rounded() }
            if let pick = inBucket.max(by: { better($1, than: $0) }) { return pick.gradeLabel }
            // Nearest by absolute distance to the level; ties broken by `better`.
            let pick = recentSends.min { a, b in
                let da = abs(a.difficulty - lvl), db = abs(b.difficulty - lvl)
                if da != db { return da < db }
                return better(a, than: b)
            }
            return pick?.gradeLabel
        }

        // Max-grade progression: best send per calendar month, chronological.
        let progression = monthlyBestSends(sendLogs, calendar: calendar)

        // Weekly send volume over the trailing window (oldest→newest, zero-filled).
        let weekly = weeklyVolume(sendLogs, now: now, calendar: calendar, weeks: max(1, weeklyVolumeWindow))

        // Angle distribution: sends & attempts per angle.
        let angles = angleDistribution(sorted)

        // All-time segmented pyramid — reuse the per-session segmentation.
        let pyramid = KilterSessionStats.segmentedPyramid(
            from: sorted, gradeLabel: \.gradeLabel, difficulty: \.difficulty, status: \.status)

        // Period roll-ups.
        let monthRollups = rollups(sorted, sessions: sessions, calendar: calendar) {
            monthKey($0, calendar: calendar)
        }
        let weekRollups = rollups(sorted, sessions: sessions, calendar: calendar) {
            weekKey($0, calendar: calendar)
        }

        return KilterAllTimeStats(
            totalSends: totalSends, totalAttempts: totalAttempts,
            totalClimbsLogged: totalClimbsLogged, distinctClimbs: distinctClimbs,
            sendRate: sendRate, flashRate: flashRate, attemptsToSend: attemptsToSend,
            maxGradeDifficulty: hardest?.difficulty, maxGradeLabel: hardest?.gradeLabel,
            climbingLevelDifficulty: climbingLevelDiff, climbingLevelLabel: climbingLevelLabel,
            maxGradeProgression: progression, sendsPerWeek: weekly, angleDistribution: angles,
            pyramid: pyramid, monthRollups: monthRollups, weekRollups: weekRollups)
    }

    // MARK: - Private aggregation helpers (all pure)

    /// Best send difficulty + label per calendar month, chronological by month.
    private static func monthlyBestSends(_ sendLogs: [KilterClimbLog],
                                         calendar: Calendar) -> [GradePoint] {
        var best: [String: (difficulty: Double, label: String)] = [:]
        for log in sendLogs {
            let key = monthKey(log.loggedAt, calendar: calendar)
            if let existing = best[key], existing.difficulty >= log.difficulty { continue }
            best[key] = (log.difficulty, log.gradeLabel)
        }
        return best
            .map { GradePoint(periodLabel: $0.key, difficulty: $0.value.difficulty,
                              gradeLabel: $0.value.label) }
            .sorted { $0.periodLabel < $1.periodLabel }
    }

    /// Sends per week for the trailing `weeks` weeks ending at `now` (oldest→newest, zero-filled so a
    /// flat-out week still shows a bar at zero).
    ///
    /// Keyed by the **normalized week-start `Date`** (not a `yearForWeekOfYear`+`weekOfYear` string).
    /// Under `.current` those two disagree at the new-year boundary — a log in the boundary week can
    /// `dateInterval`-fall into a bucket whose string key names the *other* ISO year, so it was dropped.
    /// Matching purely on the week-start date (each bucket's start vs. the start of the week containing
    /// the log) makes the assignment self-consistent for any calendar. Always emits exactly `weeks`
    /// buckets, oldest→newest; logs in weeks after the current one are ignored.
    private static func weeklyVolume(_ sendLogs: [KilterClimbLog], now: Date,
                                     calendar: Calendar, weeks: Int) -> [VolumeBucket] {
        guard let thisWeekStart = weekStart(now, calendar: calendar) else { return [] }
        // Bucket starts: this week back to `weeks - 1` weeks ago, oldest→newest. Exactly `weeks` rows.
        var buckets: [(label: String, start: Date, sends: Int)] = []
        for offset in stride(from: weeks - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeekStart)
            else { continue }
            buckets.append((weekKey(start, calendar: calendar), start, 0))
        }
        // Index by the bucket's normalized week-start instant — the only thing we match logs against.
        var indexByStart: [Date: Int] = [:]
        for (i, b) in buckets.enumerated() { indexByStart[b.start] = i }
        for log in sendLogs {
            // Each log lands in the start-of-week of its OWN timestamp; match by equal start date.
            // (Don't count weeks after the current one.)
            guard let logWeekStart = weekStart(log.loggedAt, calendar: calendar),
                  logWeekStart <= thisWeekStart,
                  let i = indexByStart[logWeekStart] else { continue }
            buckets[i].sends += 1
        }
        return buckets.map { VolumeBucket(periodLabel: $0.label, start: $0.start, sends: $0.sends) }
    }

    /// Sends & attempts per board angle, ascending by angle.
    private static func angleDistribution(_ logs: [KilterClimbLog]) -> [AngleCount] {
        var sendsByAngle: [Int: Int] = [:]
        var attemptsByAngle: [Int: Int] = [:]
        for log in logs {
            attemptsByAngle[log.angle, default: 0] += max(1, log.attempts)
            if log.isSend { sendsByAngle[log.angle, default: 0] += 1 }
        }
        let angles = Set(sendsByAngle.keys).union(attemptsByAngle.keys).sorted()
        return angles.map {
            AngleCount(angle: $0, sends: sendsByAngle[$0] ?? 0, attempts: attemptsByAngle[$0] ?? 0)
        }
    }

    /// Generic per-period roll-up: group logs by `key(loggedAt)`, tally sends + hardest send label, and
    /// count sessions from `sessions` (one per period it started in) when supplied, else from distinct
    /// `sessionId` among that period's logs.
    private static func rollups(_ logs: [KilterClimbLog],
                                sessions: [KilterSessionSummary],
                                calendar: Calendar,
                                key: (Date) -> String) -> [PeriodRollup] {
        // Session counts per period (from the explicit session list, if given).
        var sessionCountByPeriod: [String: Int] = [:]
        if !sessions.isEmpty {
            for s in sessions { sessionCountByPeriod[key(s.startedAt), default: 0] += 1 }
        }

        var sends: [String: Int] = [:]
        var hardest: [String: (difficulty: Double, label: String)] = [:]
        var distinctSessionIds: [String: Set<UUID>] = [:]
        for log in logs {
            let k = key(log.loggedAt)
            sends[k, default: 0] += log.isSend ? 1 : 0
            if log.isSend, hardest[k].map({ log.difficulty > $0.difficulty }) ?? true {
                hardest[k] = (log.difficulty, log.gradeLabel)
            }
            if let sid = log.sessionId { distinctSessionIds[k, default: []].insert(sid) }
        }

        // Every period that has logs OR (when sessions are supplied) a session that started in it.
        let periods = Set(sends.keys).union(sessionCountByPeriod.keys)
        return periods.sorted().map { k in
            let sessionCount = sessions.isEmpty
                ? (distinctSessionIds[k]?.count ?? 0)
                : (sessionCountByPeriod[k] ?? 0)
            return PeriodRollup(periodLabel: k, sessions: sessionCount,
                                sends: sends[k] ?? 0, hardestGradeLabel: hardest[k]?.label)
        }
    }

    // MARK: - Calendar key helpers

    /// `"YYYY-MM"` for the calendar month containing `date`.
    private static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// ISO-style `"YYYY-Www"` for the week containing `date` (year-for-week-of-year so week 1 doesn't
    /// collide across the new-year boundary).
    private static func weekKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// The start instant of the week containing `date` (the calendar's first weekday).
    private static func weekStart(_ date: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }
}
