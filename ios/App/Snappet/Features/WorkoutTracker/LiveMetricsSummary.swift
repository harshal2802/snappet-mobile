import Foundation
import HighlightEngine

/// Pure, device-free aggregation of a session's **live** heart-rate state for the freeform player's
/// command-bar HR pill, recovery dot, and expandable live-metrics panel (issue #158, workstream E).
///
/// It bundles the values those surfaces show — the current bpm + its zone, the running avg/max + time
/// -in-zone + redline (`WorkoutHRStats` over the live buffer so far), and the recovery readiness toward
/// rest (`RecoveryReadiness`) — computed from a plain `[HRSample]` buffer (the merged watch+BLE stream)
/// plus the user's HR profile bounds. No SwiftUI, no `MetricsSource`, no device: it reuses the already
/// -pure `WorkoutHRStats`, `RecoveryReadiness`, and `HeartRateZone`, so the panel does no HR math and the
/// aggregation is unit-tested in `SnappetTests` with no simulator. The transport that fills the buffer
/// (watch / BLE) is the device-only edge; this summary over it is not.
struct LiveMetricsSummary: Equatable, Sendable {
    /// Latest live bpm, rounded; `nil` when there's no current sample.
    let currentBpm: Int?
    /// Zone for the current bpm (`.none` when there's no sample), using the profile max where known.
    let zone: HeartRateZone
    /// Stats over the live buffer so far; `nil` for an empty buffer (the panel hides the chart/legend).
    let stats: WorkoutHRStats?
    /// Recovery toward rest from the latest bpm + profile bounds; `.unknown` (hidden) without a profile.
    let recovery: RecoveryReadiness

    /// Running average bpm, rounded; `nil` until there's a buffer.
    var avgBpm: Int? { stats.map { Int($0.avgBpm.rounded()) } }
    /// Running max bpm, rounded; `nil` until there's a buffer.
    var maxBpm: Int? { stats.map { Int($0.maxBpm.rounded()) } }
    /// Redline fraction (Z4+Z5 of total dwell), `0` when there's no dwell yet.
    var redlineFraction: Double { stats?.redlineFraction ?? 0 }
    /// Recovery toward rest, 0…1 (`0` when `.unknown`), for the recovery ring/dot fill.
    var recoveryFraction: Double { recovery.fraction }
    /// Whether there's anything to show (a current bpm or any buffered sample).
    var hasData: Bool { currentBpm != nil || stats != nil }

    /// Aggregate the live HR state from the merged sample buffer + the current reading + profile bounds.
    ///
    /// - samples: the merged live buffer (`LiveHRMerge.merge(watch, ble)`), `t` already on the session
    ///   timeline. Empty ⇒ `stats == nil`.
    /// - currentBpm: the latest live reading (`app.liveWorkout.latestHR`); `nil`/≤0 ⇒ `zone == .none`
    ///   and `recovery == .unknown`.
    /// - maxHR / restHR: the user's profile bounds (`resolvedMaxHR` / `restingBound`); `maxHR` defaults
    ///   to `HeartRateZone.defaultMaxHR` for zone color only, but `RecoveryReadiness` needs the *real*
    ///   bounds (passed through as-is) or it stays `.unknown` — exactly like every existing call site.
    static func make(from samples: [HRSample],
                     currentBpm: Double?,
                     maxHR: Double?,
                     restHR: Double?) -> LiveMetricsSummary {
        let zoneMax = maxHR ?? HeartRateZone.defaultMaxHR
        let stats = WorkoutHRStats.make(from: WorkoutHRStats.points(from: samples), maxHR: zoneMax)
        return LiveMetricsSummary(
            // Treat a 0/negative reading as "no reading" so currentBpm/hasData degrade consistently with
            // zone (.none) and recovery (.unknown) — otherwise a transient 0 bpm shows "0 bpm" beside a
            // "—" zone and suppresses the no-source state.
            currentBpm: currentBpm.flatMap { $0 > 0 ? Int($0.rounded()) : nil },
            zone: HeartRateZone.forBpm(currentBpm, maxHR: zoneMax),
            stats: stats,
            recovery: RecoveryReadiness.evaluate(currentBpm: currentBpm, restBpm: restHR, maxBpm: maxHR))
    }
}
