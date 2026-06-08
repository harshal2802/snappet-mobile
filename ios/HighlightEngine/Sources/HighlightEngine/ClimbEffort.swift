import Foundation

/// Per-climb physiological effort + recovery derived purely from a heart-rate series — the
/// climbing analogue of a single "burn". Pure, platform-free value type (engine constraint), so
/// it is unit-tested with `swift test`, no device, no simulator.
///
/// **What it measures** for one climb's `[start, end]` window on the session HR timeline:
/// - `peakBpm` / `timeToPeak`: the hardest physiological instant of the attempt and when it landed.
/// - `peakHRR`: that peak as a fraction of heart-rate-reserve — **only** when real `maxBpm`/`restBpm`
///   bounds are supplied (no user HR profile yet → `nil`, the honest bpm-only state).
/// - `hrRise`: how far HR climbed from the window's start to its peak (the surge of the effort).
/// - `hrRecovery60` / `hrRecovery30`: bpm dropped in the 60 s / 30 s **after** the peak — the
///   rest-quality signal between burns. Read past `end`, so the *caller* must pass a window whose
///   `end` reflects the logged climb end (this helper does not re-extend it).
///
/// **Why the caller extends the window, not this helper:** HR lags effort ~10–30 s and a boulder
/// problem is over in seconds, so the peak frequently lands just *after* the logged `endedAt`.
/// `KilterSessionStats` extends each climb's window end by `HighlightConfig.hrLagSec` before calling
/// `make`; the media-assignment `climbWindows` stays untouched. A zero-lag negative-control test
/// guards that the extension is what captures a just-after-end spike.
///
/// All fields are `Optional`: `.empty` (everything `nil`) when there's no HR / no window / the
/// series ends before the recovery offset — so an HR-less session renders exactly as before.
public struct ClimbEffort: Sendable, Equatable {
    /// Smoothed peak heart rate within the window (bpm), or `nil` with no usable HR.
    public let peakBpm: Double?
    /// Peak as a fraction of heart-rate-reserve (0…1), or `nil` when no `maxBpm` bound was supplied.
    public let peakHRR: Double?
    /// bpm climbed from the window start to the peak.
    public let hrRise: Double?
    /// Seconds from the window start to the peak.
    public let timeToPeak: Double?
    /// bpm dropped in the 60 s after the peak; `nil` when the series ends before `peak + 60 s`.
    public let hrRecovery60: Double?
    /// bpm dropped in the 30 s after the peak; `nil` when the series ends before `peak + 30 s`.
    public let hrRecovery30: Double?

    /// No usable HR for this climb — the all-`nil` state the UI hides on.
    public static let empty = ClimbEffort(peakBpm: nil, peakHRR: nil, hrRise: nil,
                                          timeToPeak: nil, hrRecovery60: nil, hrRecovery30: nil)

    public init(peakBpm: Double?, peakHRR: Double?, hrRise: Double?,
                timeToPeak: Double?, hrRecovery60: Double?, hrRecovery30: Double?) {
        self.peakBpm = peakBpm
        self.peakHRR = peakHRR
        self.hrRise = hrRise
        self.timeToPeak = timeToPeak
        self.hrRecovery60 = hrRecovery60
        self.hrRecovery30 = hrRecovery30
    }

    /// Score one climb's effort over `[start, end]` (seconds on the session HR timeline).
    ///
    /// Reuses the engine's `HeartRateSeries` resample→smooth so the peak/recovery read a clean
    /// signal (not a jagged raw series), with the **same** `%HRR` math the rest of the app uses.
    /// The grid spans the whole `samples` series, so recovery can read past `end`; the peak is
    /// searched only within `[start, min(end, lastSampleTime)]` (never over held padding).
    ///
    /// - Parameters:
    ///   - samples: the session HR series (any order; `t` seconds from session start).
    ///   - start: window start (seconds). - end: window end (seconds; caller-extended by HR lag).
    ///   - restBpm/maxBpm: HR bounds for `%HRR`; when `maxBpm` is `nil`, `peakHRR` is `nil`.
    ///   - smoothingWindowSec: smoothing window (the climbing preset uses 5 s).
    public static func make(from samples: [HRSample],
                            start: Double,
                            end: Double,
                            restBpm: Double?,
                            maxBpm: Double?,
                            smoothingWindowSec: Double = 5) -> ClimbEffort {
        let sorted = samples.sorted { $0.t < $1.t }
        guard let lastT = sorted.last?.t, end >= start else { return .empty }

        let dt = 1.0
        let duration = max(lastT, end, dt)
        let series = HeartRateSeries.make(from: sorted, duration: duration, dt: dt,
                                          smoothingWindowSec: smoothingWindowSec,
                                          restBpm: restBpm, maxBpm: maxBpm)

        // Find the peak within the window, but never past real data (the grid holds the last value
        // beyond `lastT`, which must not masquerade as a peak).
        let searchEnd = Swift.min(end, lastT)
        guard searchEnd >= start else { return .empty }
        let lo = series.index(for: start)
        let hi = series.index(for: searchEnd)
        var peakIdx = lo
        if hi > lo {
            for i in (lo + 1)...hi where series.bpm[i] > series.bpm[peakIdx] { peakIdx = i }
        }
        let peakT = Double(peakIdx) * series.dt
        let peak = series.bpm[peakIdx]
        let startBpm = series.bpm(at: start)

        // %HRR only when a real max-HR bound exists (no user profile yet → nil, the honest state).
        let peakHRR: Double? = maxBpm != nil ? series.hrr(at: peakT) : nil

        // Recovery reads smoothed HR `offset` seconds past the peak — only if real data reaches it.
        func recovery(after offset: Double) -> Double? {
            guard lastT >= peakT + offset else { return nil }
            return peak - series.bpm(at: peakT + offset)
        }

        return ClimbEffort(peakBpm: peak,
                           peakHRR: peakHRR,
                           hrRise: peak - startBpm,
                           timeToPeak: peakT - start,
                           hrRecovery60: recovery(after: 60),
                           hrRecovery30: recovery(after: 30))
    }
}
