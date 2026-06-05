import Foundation

/// Tunable parameters for highlight detection. Every knob the research called out
/// lives here so the algorithm is configurable without code changes — this is what
/// makes the "optimize later from real data" loop possible. Persist a `HighlightConfig`
/// per user/experiment and A/B different values once real sessions exist.
public struct HighlightConfig: Sendable, Equatable {
    /// Smoothing window for HR (seconds). Research suggested ~5–15 s.
    public var smoothingWindowSec: Double
    /// HR lags the real moment; look this many seconds *after* a moment when
    /// scoring it, and bias clip windows earlier. (#60 §3/§4)
    public var hrLagSec: Double
    /// Weight on %HRR peak level vs rate-of-change. wLevel + wSlope need not sum to 1.
    public var wLevel: Double
    public var wSlope: Double
    /// Fraction of returned highlights that should be "low"/recovery moments
    /// (for pacing/contrast). 0 = all high.
    public var lowMomentFraction: Double
    /// Clip padding around a peak (seconds), biased earlier by `hrLagSec`.
    public var clipLeadSec: Double
    public var clipTrailSec: Double
    /// Minimum gap between two chosen highlights (seconds) — non-max suppression.
    public var minGapSec: Double
    /// Max number of highlights to return (the reel's raw candidate set).
    public var maxHighlights: Int
    /// When `true`, the selector still picks *which* media to feature via HR (NMS + `maxHighlights`),
    /// but emits each as a **full-length** clip (the whole media item) rather than a trimmed window,
    /// and collapses repeated moments in one media to a single segment. Paired with an uncapped
    /// `ReelPlanner` (`targetDuration: nil`) this produces full-length, uncapped reels. Default `false`
    /// preserves the original trimmed-highlight behavior.
    public var fullClips: Bool

    public init(
        smoothingWindowSec: Double = 9,
        hrLagSec: Double = 6,
        wLevel: Double = 0.6,
        wSlope: Double = 0.4,
        lowMomentFraction: Double = 0.2,
        clipLeadSec: Double = 6,
        clipTrailSec: Double = 4,
        minGapSec: Double = 20,
        maxHighlights: Int = 8,
        fullClips: Bool = false
    ) {
        self.smoothingWindowSec = smoothingWindowSec
        self.hrLagSec = hrLagSec
        self.wLevel = wLevel
        self.wSlope = wSlope
        self.lowMomentFraction = lowMomentFraction
        self.clipLeadSec = clipLeadSec
        self.clipTrailSec = clipTrailSec
        self.minGapSec = minGapSec
        self.maxHighlights = maxHighlights
        self.fullClips = fullClips
    }

    public static let `default` = HighlightConfig()

    /// A copy of this config with `fullClips` enabled — used by the app's reel paths so each featured
    /// clip plays in full (no per-clip trim). Combine with `ReelPlanner(targetDuration: nil)` to also
    /// drop the total-length cap.
    public func fullLength() -> HighlightConfig {
        var c = self
        c.fullClips = true
        return c
    }

    /// Per-activity presets (best guess — to be tuned from real data, #60 §4).
    /// Climbing = bursty (short clips, less smoothing); running = sustained
    /// (more smoothing, longer clips); dance = rhythmic (favor sustained highs).
    public static func preset(for activity: Activity) -> HighlightConfig {
        switch activity {
        case .climbing:
            return HighlightConfig(smoothingWindowSec: 5, wLevel: 0.45, wSlope: 0.55,
                                   clipLeadSec: 4, clipTrailSec: 3, minGapSec: 15, maxHighlights: 10)
        case .running:
            return HighlightConfig(smoothingWindowSec: 13, wLevel: 0.7, wSlope: 0.3,
                                   clipLeadSec: 7, clipTrailSec: 4, minGapSec: 25, maxHighlights: 7)
        case .dance:
            return HighlightConfig(smoothingWindowSec: 9, wLevel: 0.65, wSlope: 0.35,
                                   lowMomentFraction: 0.1, clipLeadSec: 5, clipTrailSec: 4,
                                   minGapSec: 18, maxHighlights: 9)
        case .strength, .other:
            return .default
        }
    }
}
