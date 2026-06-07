import Foundation

/// A plain-value view of one logged climb, so session statistics are computed (and unit-tested in
/// `SnappetTests`) **without** touching the SwiftData `KilterLogEntry` @Model. `KilterSessionStats`
/// works on `[KilterClimbLog]`; views build them with `KilterClimbLog.from(_:)`.
struct KilterClimbLog: Sendable, Equatable {
    var climbUUID: String
    var climbName: String
    var gradeLabel: String
    var difficulty: Double
    var status: KilterAscentStatus
    var attempts: Int
    var startedAt: Date?
    var endedAt: Date?
    /// The log timestamp (`KilterLogEntry.date`) — the fallback "end" when `endedAt` is nil.
    var loggedAt: Date

    var isSend: Bool { status.isSend }
    /// Effective end for timing: explicit `endedAt`, else the log timestamp.
    var effectiveEnd: Date { endedAt ?? loggedAt }
    /// Effective start for timing: explicit `startedAt`, else the effective end (zero-length).
    var effectiveStart: Date { startedAt ?? effectiveEnd }
    /// Time spent working this climb, when a start is known.
    var timeOnClimb: TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, effectiveEnd.timeIntervalSince(startedAt))
    }
}

/// Pure, device-free statistics over a Kilter climbing session's logged climbs — the climbing
/// analogue of `WorkoutHRStats`. The summary view does no math; it reads a precomputed value.
/// Everything here is unit-testable with synthetic `KilterClimbLog`s (no SwiftData, no device).
struct KilterSessionStats: Sendable, Equatable {
    /// Total logged entries (sends + projects + attempts).
    var totalClimbs: Int
    var sends: Int
    var projects: Int
    /// Climbs left in the `.attempt` state (tried but not sent or marked a project).
    var attemptsOnly: Int
    /// Total tries across all climbs (sum of each climb's `attempts`) — the session's "effort" number,
    /// and the figure that matches the per-climb "N attempts" in the timeline.
    var totalAttempts: Int
    /// Hardest **send** by float difficulty, with its grade label — `nil` when nothing was sent.
    var hardestSendDifficulty: Double?
    var hardestSendGrade: String?
    /// Sends per hour over the session duration (0 when the session has no measurable length).
    var sendsPerHour: Double
    /// Sends grouped by grade, ordered easiest→hardest — the History/summary grade pyramid.
    var pyramid: [GradeCount]
    /// One row per logged climb in chronological order, with time-on-climb and the rest taken
    /// before it (gap since the previous climb's end).
    var timeline: [TimelineItem]
    /// Session length in seconds (`end − start`).
    var totalDuration: TimeInterval
    /// Median time-on-climb across climbs that recorded one — `nil` if none did.
    var medianTimeOnClimb: TimeInterval?

    struct GradeCount: Sendable, Equatable, Identifiable {
        var gradeLabel: String
        var difficulty: Double
        var sends: Int
        var id: String { gradeLabel }
    }

    struct TimelineItem: Sendable, Equatable, Identifiable {
        /// Stable position in the session (a climb UUID can repeat, so the index is the id).
        var index: Int
        var climbUUID: String
        var climbName: String
        var gradeLabel: String
        var status: KilterAscentStatus
        var attempts: Int
        var timeOnClimb: TimeInterval?
        /// Rest taken before this climb (gap since the previous climb's effective end); `nil` first.
        var restBefore: TimeInterval?
        var id: Int { index }
    }

    /// Compute stats from a session's logged climbs and its `[start, end]` interval. Logs are
    /// ordered chronologically by effective start; an empty session yields all-zero stats.
    static func make(from logs: [KilterClimbLog], start: Date, end: Date) -> KilterSessionStats {
        let duration = max(0, end.timeIntervalSince(start))
        let sorted = logs.sorted { $0.effectiveStart < $1.effectiveStart }

        let sendLogs = sorted.filter(\.isSend)
        let sends = sendLogs.count
        let projects = sorted.filter { $0.status == .project }.count
        let attemptsOnly = sorted.filter { $0.status == .attempt }.count
        let totalAttempts = sorted.reduce(0) { $0 + max(1, $1.attempts) }

        let hardest = sendLogs.max { $0.difficulty < $1.difficulty }
        let sendsPerHour = duration > 0 ? Double(sends) / (duration / 3600) : 0

        // Grade pyramid: sends per grade label, easiest→hardest by representative difficulty.
        var byGrade: [String: (difficulty: Double, count: Int)] = [:]
        for log in sendLogs {
            let existing = byGrade[log.gradeLabel]
            byGrade[log.gradeLabel] = (log.difficulty, (existing?.count ?? 0) + 1)
        }
        let pyramid = byGrade
            .map { GradeCount(gradeLabel: $0.key, difficulty: $0.value.difficulty, sends: $0.value.count) }
            .sorted { $0.difficulty < $1.difficulty }

        // Chronological timeline with rest-before derived across consecutive climbs.
        var timeline: [TimelineItem] = []
        var previousEnd: Date?
        for (i, log) in sorted.enumerated() {
            let rest = previousEnd.map { max(0, log.effectiveStart.timeIntervalSince($0)) }
            timeline.append(TimelineItem(
                index: i, climbUUID: log.climbUUID, climbName: log.climbName,
                gradeLabel: log.gradeLabel, status: log.status, attempts: log.attempts,
                timeOnClimb: log.timeOnClimb, restBefore: rest))
            previousEnd = log.effectiveEnd
        }

        let times = sorted.compactMap(\.timeOnClimb).sorted()
        let median = times.isEmpty ? nil : medianOf(times)

        return KilterSessionStats(
            totalClimbs: sorted.count, sends: sends, projects: projects, attemptsOnly: attemptsOnly,
            totalAttempts: totalAttempts,
            hardestSendDifficulty: hardest?.difficulty, hardestSendGrade: hardest?.gradeLabel,
            sendsPerHour: sendsPerHour, pyramid: pyramid, timeline: timeline,
            totalDuration: duration, medianTimeOnClimb: median)
    }

    /// Median of a **sorted, non-empty** array (mean of the two middle values for an even count).
    private static func medianOf(_ sorted: [TimeInterval]) -> TimeInterval {
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}

extension KilterClimbLog {
    /// Map a SwiftData `KilterLogEntry` to the plain-value log used by `KilterSessionStats`.
    static func from(_ entry: KilterLogEntry) -> KilterClimbLog {
        KilterClimbLog(
            climbUUID: entry.climbUUID, climbName: entry.climbName, gradeLabel: entry.gradeLabel,
            difficulty: entry.difficulty, status: entry.status, attempts: entry.attempts,
            startedAt: entry.startedAt, endedAt: entry.endedAt, loggedAt: entry.date)
    }
}
