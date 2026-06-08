import Foundation
import HighlightEngine

/// Pure, device-free heart-rate statistics over a session's persisted `hrSeries`.
///
/// This lives in the app (not `HighlightEngine`) because it depends on the app's
/// `HeartRateZone` (which vends a SwiftUI `Color`) — but its *logic* is platform-free, so
/// avg/max/min + per-zone dwell-time are unit-testable in `SnappetTests` with no device
/// and no simulator (mirrors keeping the engine platform-free; B2). The summary view does
/// no HR math — it reads a precomputed `WorkoutHRStats`.
struct WorkoutHRStats: Equatable, Sendable {
    let avgBpm: Double
    let maxBpm: Double
    let minBpm: Double
    /// Seconds spent in each real zone (recovery…max), keyed by zone. `.none` never appears.
    let secondsByZone: [HeartRateZone: Double]

    /// Total dwell time accounted for across the real zones, in seconds.
    var totalSeconds: Double { secondsByZone.values.reduce(0, +) }

    /// Compute stats from a session's HR series. Returns `nil` for an **empty** series so the
    /// summary can hide the whole HR section. A **single-sample** series yields avg=max=min
    /// at that bpm and zero dwell time (one point has no interval to attribute).
    ///
    /// Time-in-zone uses a left-edge attribution: each sample's zone (from `HeartRateZone.forBpm`)
    /// "owns" the interval until the next sample, so the dwell sums to the series' span. The last
    /// sample contributes no interval (nothing follows it).
    static func make(from series: [HRPoint], maxHR: Double = HeartRateZone.defaultMaxHR) -> WorkoutHRStats? {
        guard !series.isEmpty else { return nil }

        let sorted = series.sorted { $0.t < $1.t }
        let bpms = sorted.map(\.bpm)
        let avg = bpms.reduce(0, +) / Double(bpms.count)
        let maxV = bpms.max() ?? 0
        let minV = bpms.min() ?? 0

        var byZone: [HeartRateZone: Double] = [:]
        if sorted.count > 1 {
            for i in 0..<(sorted.count - 1) {
                let dwell = max(0, sorted[i + 1].t - sorted[i].t)
                guard dwell > 0 else { continue }
                let zone = HeartRateZone.forBpm(sorted[i].bpm, maxHR: maxHR)
                guard zone != .none else { continue }
                byZone[zone, default: 0] += dwell
            }
        }

        return WorkoutHRStats(avgBpm: avg, maxBpm: maxV, minBpm: minV, secondsByZone: byZone)
    }

    /// The real zones (recovery…max) ordered low→high, paired with their dwell seconds
    /// (0 when unused) — the stable order the summary's zone bar/legend renders.
    var orderedZoneSeconds: [(zone: HeartRateZone, seconds: Double)] {
        HeartRateZone.allCases
            .filter { $0 != .none }
            .sorted { $0.rawValue < $1.rawValue }
            .map { (zone: $0, seconds: secondsByZone[$0] ?? 0) }
    }

    /// Seconds spent at "redline" — the two hard zones (Z4 threshold + Z5 max). For bursty climbing
    /// this is the figure that characterizes a session: how long you were genuinely maxed out.
    var redlineSeconds: Double {
        (secondsByZone[.threshold] ?? 0) + (secondsByZone[.max] ?? 0)
    }

    /// Redline time as a fraction (0…1) of the total in-zone dwell; `0` when there's no dwell
    /// (single-sample / empty) so the UI never divides by zero or shows NaN.
    var redlineFraction: Double {
        totalSeconds > 0 ? redlineSeconds / totalSeconds : 0
    }

    /// Edwards' zone-weighted training load (TRIMP): Σ minutes-in-zone × zone-weight, where the
    /// weight is the zone number (recovery = 1 … max = 5) — a single session-strain figure.
    /// Anchored to the current fixed `defaultMaxHR` until a user HR profile lands, so it reads as a
    /// within-user *trend*, not a cross-user or clinical number (decisions.md 2026-06-08).
    var edwardsTRIMP: Double {
        secondsByZone.reduce(0) { $0 + ($1.value / 60) * Double($1.key.rawValue) }
    }
}

extension WorkoutHRStats {
    /// Map a live `MetricsSource` buffer (engine `HRSample`s, `t` already rebased onto the
    /// session timeline) to the persisted `HRPoint` composite. A straight 1:1 field copy —
    /// isolated here so the flush in `finishWorkout` is a one-liner and the mapping is tested.
    static func points(from samples: [HRSample]) -> [HRPoint] {
        samples.map { HRPoint(t: $0.t, bpm: $0.bpm) }
    }
}
