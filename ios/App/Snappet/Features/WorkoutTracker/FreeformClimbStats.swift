import Foundation
import HighlightEngine

/// Pure bridge from a freeform session's CLIMB exercises to the rich `KilterSessionStats` (sends,
/// hardest send, grade pyramid, sends/hr, time-on-wall) — so the live stats ribbon + completion recap
/// reuse the exact statistics the Kilter board flow already computes, instead of re-deriving them. Each
/// `.climbAttempt` `SessionExercise` (a climb) becomes one `KilterClimbLog`; its float difficulty comes
/// from the scale-aware `GradeScale.difficulty`. No SwiftUI/SwiftData/device → unit-tested in SnappetTests
/// (the repo's pure-logic-at-a-thin-edge rule; shipped ahead of its ribbon/summary callers like
/// `StopwatchTiming`). (Quick Session redesign — Phase 3 logic, foundation-first.)
enum FreeformClimbStats {

    /// Map one climb exercise to a plain-value climb log, or `nil` if it has no completed attempt yet
    /// (a freshly-added climb contributes nothing to stats until its first effort is logged).
    static func log(for ex: SessionExercise) -> KilterClimbLog? {
        guard ex.kind == .climbAttempt else { return nil }
        let completed = ex.sets.filter { $0.completedAt != nil }
        guard !completed.isEmpty else { return nil }

        // Grade: the climb-level grade (source of truth), else the first attempt's stamped grade (old
        // data / safety), else empty. Difficulty is the scale ordinal — exact within a discipline.
        let grade = ex.climbGradeLabel
            ?? completed.compactMap { $0.climbGradeLabel }.first
            ?? ""
        let difficulty = ex.climbGradeScale.difficulty(for: grade) ?? 0
        let status = ex.resolvedClimbStatus ?? .attempt
        // Total bids on the climb = sum of each attempt-log's bid count (default 1) — matches the
        // KilterSessionStats `totalAttempts` semantics (`sum max(1, attempts)`).
        let attempts = max(1, completed.reduce(0) { $0 + max(1, $1.climbAttempts ?? 1) })

        // Climb window from attempt timestamps: a timed attempt's start is its `completedAt` minus its
        // captured duration; the climb starts at the earliest such start and ends at the last stamp.
        let stamps = completed.compactMap { $0.completedAt }
        let starts = completed.compactMap { set -> Date? in
            guard let c = set.completedAt else { return nil }
            return c.addingTimeInterval(-(set.durationSec ?? 0))
        }
        let startedAt = starts.min()
        let endedAt = stamps.max()

        return KilterClimbLog(
            climbUUID: ex.id.uuidString, climbName: ex.displayName ?? "Climbing",
            gradeLabel: grade, difficulty: difficulty, status: status, attempts: attempts,
            startedAt: startedAt, endedAt: endedAt, loggedAt: endedAt ?? .now)
    }

    /// Climb logs for a whole session (each climb that has ≥1 completed attempt).
    static func logs(for session: WorkoutSession) -> [KilterClimbLog] {
        session.exercises.compactMap(log(for:))
    }

    /// Live/finished climbing stats for a session — sends, hardest, pyramid, sends/hr, time-on-wall.
    /// `now` is the live "end" while the session is active (`completedAt == nil`); `hrSeries` (optional)
    /// scores per-climb effort for the completion recap (empty for the live ribbon).
    static func stats(for session: WorkoutSession, now: Date = .now,
                      hrSeries: [HRSample] = []) -> KilterSessionStats {
        let logs = logs(for: session)
        let end = session.completedAt ?? now
        return KilterSessionStats.make(from: logs, start: session.startedAt, end: end,
                                       hrSeries: hrSeries, maxHR: session.maxHR, restHR: session.restHR)
    }

    /// Whether a session has any logged climbing at all (drives showing the stats ribbon).
    static func hasClimbing(_ session: WorkoutSession) -> Bool {
        session.exercises.contains { $0.kind == .climbAttempt && $0.sets.contains { $0.completedAt != nil } }
    }
}
