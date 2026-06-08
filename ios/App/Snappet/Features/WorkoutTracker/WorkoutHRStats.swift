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

extension WorkoutHRStats {
    /// Identifies one logged set within a session, for per-set effort lookup.
    struct SetRef: Hashable, Sendable {
        let exerciseID: UUID
        let setIndex: Int
        init(exerciseID: UUID, setIndex: Int) {
            self.exerciseID = exerciseID
            self.setIndex = setIndex
        }
    }

    /// Per-set effort + recovery across a whole session, computed over the persisted `hrSeries`
    /// (reusing the engine's `ClimbEffort`). The WorkoutTracker analogue of the Kilter per-climb
    /// effort, generalized to **every `SetKind`** a Quick / freeform session can log:
    ///
    /// - Window **end** = the set's `completedAt + hrLagSec` for every kind (HR lags effort; an
    ///   anaerobic set's HR peak typically lands at / just after completion).
    /// - Window **start** depends on the kind's available timing:
    ///   - `.duration` (timed hold): `completedAt − durationSec` — the known work interval.
    ///   - `.repsWeight` / `.climbAttempt` (no recorded duration): a lookback to the **previous
    ///     chronological** set's completion (HR doesn't reset across exercises), capped at
    ///     `maxLookback` so the first set, or a long rest between sets, can't balloon the window.
    ///
    /// Only completed sets are scored; sets without `completedAt`, and every set when `hr` is empty,
    /// are absent from the map (callers default to `.empty`). `maxHR == nil` (no profile yet) → the
    /// efforts carry peak bpm but no `peakHRR` (the honest bpm-only state). Pure + deterministic →
    /// unit-tested with no device.
    static func setEfforts(for exercises: [SessionExercise],
                           sessionStart: Date,
                           hr: [HRSample],
                           maxHR: Double? = nil,
                           restHR: Double? = nil,
                           config: HighlightConfig = .preset(for: .strength),
                           maxLookback: Double = 120) -> [SetRef: ClimbEffort] {
        guard !hr.isEmpty else { return [:] }

        struct Entry { let ref: SetRef; let completedAt: Date; let kind: SetKind; let durationSec: Double? }
        var entries: [Entry] = []
        for ex in exercises {
            for (i, set) in ex.sets.enumerated() {
                guard let done = set.completedAt else { continue }
                entries.append(Entry(ref: SetRef(exerciseID: ex.id, setIndex: i),
                                     completedAt: done, kind: ex.kind, durationSec: set.durationSec))
            }
        }
        entries.sort { $0.completedAt < $1.completedAt }

        var result: [SetRef: ClimbEffort] = [:]
        var previousCompletedAt: Date?
        for e in entries {
            let endOffset = max(0, e.completedAt.timeIntervalSince(sessionStart))
            let lookback: Double
            if e.kind == .duration, let d = e.durationSec, d > 0 {
                lookback = d
            } else if let prev = previousCompletedAt {
                lookback = min(maxLookback, max(0, e.completedAt.timeIntervalSince(prev)))
            } else {
                lookback = maxLookback
            }
            result[e.ref] = ClimbEffort.make(from: hr,
                                             start: max(0, endOffset - lookback),
                                             end: endOffset + config.hrLagSec,
                                             restBpm: restHR, maxBpm: maxHR,
                                             smoothingWindowSec: config.smoothingWindowSec)
            previousCompletedAt = e.completedAt
        }
        return result
    }
}
