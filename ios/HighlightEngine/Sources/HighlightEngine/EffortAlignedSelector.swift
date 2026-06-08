import Foundation

/// A `HighlightSelector` that favors moments inside **achievement windows** — sent-climb windows
/// (Kilter) or peak-effort set windows (WorkoutTracker) — so an auto-reel features the *achievement*,
/// not just the raw HR peak (fitness-band Phase 4). Same pure protocol surface as
/// `HRHighlightSelector`/`SceneHighlightSelector`, and it composes with HR via `FusionSelector`, so
/// it's a drop-in: with no windows it scores 0 (fusion ⇒ HR-only, today's behavior).
///
/// Platform-free + deterministic → `swift test`'d, no device.
public struct EffortAlignedSelector: HighlightSelector {
    /// Achievement windows in seconds from session start (the engine offset timeline).
    public let windows: [ClosedRange<Double>]
    /// Score returned for an offset inside any window (tuned to sit alongside the ~0…1 HR score).
    public let boost: Double

    public init(windows: [ClosedRange<Double>], boost: Double = 1.0) {
        self.windows = windows
        self.boost = boost
    }

    public func score(at offset: Double, workout: Workout, hr: HeartRateSeries, config: HighlightConfig) -> Double {
        windows.contains(where: { $0.contains(offset) }) ? boost : 0
    }
}

public extension FusionSelector {
    /// HR blended with the effort-aligned boost — the Phase-4 reel selector. Empty `windows` ⇒ the
    /// effort part contributes 0 everywhere ⇒ pure HR ranking (gated, no behavior change).
    static func effortAligned(windows: [ClosedRange<Double>],
                              hrWeight: Double = 0.6, effortWeight: Double = 0.4) -> FusionSelector {
        FusionSelector([(HRHighlightSelector(), hrWeight),
                        (EffortAlignedSelector(windows: windows), effortWeight)])
    }
}
