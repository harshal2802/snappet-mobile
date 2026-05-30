import Foundation

/// The swappable strategy that turns a workout + media into ranked highlights.
///
/// MODULARITY IS THE POINT: the spike (Snappet#60 / experiments/) concluded the
/// real-world winner is probably a *fusion* of HR + content signals, not HR alone.
/// So selection is a protocol with multiple implementations; the app picks one (or
/// fuses) and can swap the default once real data arrives — no UI/pipeline changes.
public protocol HighlightSelector: Sendable {
    /// Score a candidate moment (seconds from workout start). Higher = better.
    /// Selectors only score; ranking/NMS/padding is shared (see `select`).
    func score(at offset: Double, workout: Workout, hr: HeartRateSeries, config: HighlightConfig) -> Double
}

public extension HighlightSelector {
    /// Shared selection pipeline: enumerate candidates within filmed media,
    /// score, rank, non-max suppress, pad, and split into high/low. Identical for
    /// every selector so they're compared apples-to-apples (matches the spike).
    func select(workout: Workout, config: HighlightConfig, candidateStepSec: Double = 1.0) -> [Highlight] {
        guard !workout.media.isEmpty else { return [] }
        let hr = HeartRateSeries.make(
            from: workout.hr, duration: workout.duration,
            smoothingWindowSec: config.smoothingWindowSec,
            restBpm: workout.restBpm, maxBpm: workout.maxBpm
        )

        // Candidate moments: only where media exists (we can only show filmed time).
        struct Cand { let t: Double; let media: MediaItem; let s: Double }
        var cands: [Cand] = []
        for media in workout.media {
            if media.kind == .photo {
                cands.append(Cand(t: media.startOffset, media: media,
                                  s: score(at: media.startOffset, workout: workout, hr: hr, config: config)))
            } else {
                var t = media.startOffset
                while t <= media.endOffset {
                    cands.append(Cand(t: t, media: media,
                                      s: score(at: t, workout: workout, hr: hr, config: config)))
                    t += candidateStepSec
                }
            }
        }
        guard !cands.isEmpty else { return [] }

        // Rank, then greedy non-max suppression by time gap.
        let ranked = cands.sorted { $0.s > $1.s }
        var chosen: [Cand] = []
        for c in ranked {
            if chosen.allSatisfy({ abs($0.t - c.t) >= config.minGapSec }) {
                chosen.append(c)
            }
            if chosen.count >= config.maxHighlights { break }
        }

        // Split high vs low by median score; label the bottom `lowMomentFraction`.
        let scores = chosen.map(\.s).sorted()
        let lowCount = Int((Double(chosen.count) * config.lowMomentFraction).rounded(.down))
        let lowThreshold = lowCount > 0 ? scores[max(0, lowCount - 1)] : -Double.infinity

        return chosen.enumerated().map { (i, c) in
            let kind: Highlight.Kind = c.s <= lowThreshold ? .low : .high
            // Pad, biased earlier (HR lags the moment). Clamp inside the media item.
            let center = c.t - config.hrLagSec
            let start = max(c.media.startOffset, center - config.clipLeadSec)
            let end = c.media.kind == .photo
                ? c.media.startOffset
                : min(c.media.endOffset, center + config.clipTrailSec)
            return Highlight(
                id: "hl-\(i)-\(c.media.id)", mediaItemId: c.media.id, kind: kind,
                atOffset: c.t, clipStart: start, clipEnd: max(start, end), score: c.s
            )
        }
        .sorted { $0.atOffset < $1.atOffset }   // chronological for the reel
    }
}

// MARK: - HR-based selector (the best-guess default, #60 §4)

public struct HRHighlightSelector: HighlightSelector {
    public init() {}
    public func score(at offset: Double, workout: Workout, hr: HeartRateSeries, config: HighlightConfig) -> Double {
        // HR lags the moment → look slightly *after* the moment.
        let u = offset + config.hrLagSec
        return config.wLevel * hr.hrr(at: u) + config.wSlope * hr.slope(at: u)
    }
}

// MARK: - Content/scene selector (stub for fusion — fill in on-device later)

/// Placeholder for a future on-device visual-saliency / motion selector. The spike
/// showed a content signal is complementary to HR, so this exists from day one to
/// keep the fusion path real. Until a real vision pipeline is wired, it returns 0
/// (i.e. fusion == HR-only) so the app is fully functional now.
public struct SceneHighlightSelector: HighlightSelector {
    /// Inject real per-offset visual scores once a vision pipeline exists.
    public var visualScore: (@Sendable (Double) -> Double)?
    public init(visualScore: (@Sendable (Double) -> Double)? = nil) { self.visualScore = visualScore }
    public func score(at offset: Double, workout: Workout, hr: HeartRateSeries, config: HighlightConfig) -> Double {
        visualScore?(offset) ?? 0
    }
}

// MARK: - Fusion (the spike's predicted real-world winner)

/// Weighted blend of any selectors. Default weighting leans HR but keeps content in
/// the mix so that, the moment a real `SceneHighlightSelector` is supplied, the app
/// upgrades to fusion with no other changes.
public struct FusionSelector: HighlightSelector {
    public let parts: [(selector: any HighlightSelector, weight: Double)]
    public init(_ parts: [(any HighlightSelector, Double)]) {
        self.parts = parts.map { (selector: $0.0, weight: $0.1) }
    }
    public static func hrLeaning(scene: SceneHighlightSelector = SceneHighlightSelector()) -> FusionSelector {
        FusionSelector([(HRHighlightSelector(), 0.7), (scene, 0.3)])
    }
    public func score(at offset: Double, workout: Workout, hr: HeartRateSeries, config: HighlightConfig) -> Double {
        parts.reduce(0) { $0 + $1.weight * $1.selector.score(at: offset, workout: workout, hr: hr, config: config) }
    }
}
