import Foundation
import HighlightEngine

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

    /// The session's single hardest physiological instant as %HRR across all scored climbs — `nil`
    /// when no climb had HR, or no max-HR bound was set (the bpm-only state).
    var sessionPeakHRR: Double? { timeline.compactMap(\.peakHRR).max() }

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
        // Per-climb heart-rate effort, derived from the session HR series over the climb's window
        // (extended past its end by the HR lag). All `nil` for HR-less sessions or climbs with no
        // recorded start; `peakHRR` also `nil` until a real max-HR bound exists (bpm-only state).
        // The effort UI hides on `peakBpm == nil`.
        var peakBpm: Double? = nil
        var peakHRR: Double? = nil
        var hrRise: Double? = nil
        var timeToPeak: TimeInterval? = nil
        var hrRecovery60: Double? = nil
        var hrRecovery30: Double? = nil
        var id: Int { index }
    }

    /// Compute stats from a session's logged climbs and its `[start, end]` interval. Logs are
    /// ordered chronologically by effective start; an empty session yields all-zero stats.
    ///
    /// `hrSeries` (the session HR samples, `t` seconds from `start`) is optional: when present, each
    /// climb that recorded a start is scored for per-climb effort/recovery; when empty, every
    /// `TimelineItem`'s effort fields stay `nil` (HR-less sessions render exactly as before).
    /// `maxHR`/`restHR` are the %HRR bounds (no user profile yet → typically `nil` → bpm-only).
    static func make(from logs: [KilterClimbLog], start: Date, end: Date,
                     hrSeries: [HRSample] = [], maxHR: Double? = nil, restHR: Double? = nil,
                     config: HighlightConfig = .preset(for: .climbing)) -> KilterSessionStats {
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
            // Per-climb HR effort: score the climb's window, extending its END by the HR lag so a
            // post-effort spike that lands just after `endedAt` is captured. We compute the window
            // here from the log's own timestamps (NOT KilterBoardController.climbWindows, which feeds
            // media auto-assignment and must keep its un-extended end). Empty for HR-less sessions or
            // climbs with no recorded start.
            let effort: ClimbEffort = {
                guard !hrSeries.isEmpty, log.startedAt != nil else { return .empty }
                let winStart = max(0, log.effectiveStart.timeIntervalSince(start))
                let winEnd = max(winStart, log.effectiveEnd.timeIntervalSince(start) + config.hrLagSec)
                return ClimbEffort.make(from: hrSeries, start: winStart, end: winEnd,
                                        restBpm: restHR, maxBpm: maxHR,
                                        smoothingWindowSec: config.smoothingWindowSec)
            }()
            timeline.append(TimelineItem(
                index: i, climbUUID: log.climbUUID, climbName: log.climbName,
                gradeLabel: log.gradeLabel, status: log.status, attempts: log.attempts,
                timeOnClimb: log.timeOnClimb, restBefore: rest,
                peakBpm: effort.peakBpm, peakHRR: effort.peakHRR, hrRise: effort.hrRise,
                timeToPeak: effort.timeToPeak, hrRecovery60: effort.hrRecovery60,
                hrRecovery30: effort.hrRecovery30))
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

/// Pure decision logic for **recovering** the active Kilter session from the persisted store after the
/// in-memory `KilterSessionManager` was reset (navigation, relaunch) or when duplicate open sessions
/// have accrued. Enforces a single-open-session invariant and auto-closes abandoned sessions, so the
/// manager and the store can't drift. Device-free + deterministic → unit-tested without SwiftData.
/// (kilter session lifecycle)
enum KilterSessionRecovery {
    /// One persisted open (`endedAt == nil`) session, reduced to what the decision needs.
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var startedAt: Date
        /// The last real activity in the session (newest log time / HR sample), else `startedAt`.
        var lastActivity: Date
    }

    /// A session to auto-close, stamped at its last real activity (not "now"), so its duration and the
    /// media-discovery window reflect when climbing actually stopped — not when we happened to notice.
    struct Closure: Equatable, Hashable, Sendable {
        var id: UUID
        var endedAt: Date
    }

    /// The recovery decision: at most one session to `adopt` as the live one, plus any to `close`.
    struct Plan: Equatable, Sendable {
        var adopt: UUID?
        var close: [Closure]
        static let empty = Plan(adopt: nil, close: [])
    }

    /// Decide which open session (if any) to adopt and which to close.
    /// - The **newest** open session is adopted, unless it's been idle longer than `abandonedAfter`
    ///   (no logs/HR for hours → the user forgot to end it), in which case it too is auto-closed.
    /// - Every **other** open session is closed (single-open invariant — duplicates can't survive).
    /// - Closed sessions are stamped at their own `lastActivity`, never "now".
    static func plan(open: [Candidate], now: Date, abandonedAfter: TimeInterval = 6 * 3600) -> Plan {
        guard !open.isEmpty else { return .empty }
        let sorted = open.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id.uuidString > $1.id.uuidString
        }
        let newest = sorted[0]
        let newestIsLive = now.timeIntervalSince(newest.lastActivity) <= abandonedAfter
        let adopt = newestIsLive ? newest.id : nil
        let close = sorted
            .filter { $0.id != adopt }
            .map { Closure(id: $0.id, endedAt: max($0.startedAt, $0.lastActivity)) }
        return Plan(adopt: adopt, close: close)
    }
}
