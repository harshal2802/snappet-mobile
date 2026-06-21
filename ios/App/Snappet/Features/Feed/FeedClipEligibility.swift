import Foundation
import HighlightEngine

// MARK: - Recap Feed — clipReady eligibility + ReelPlan ranking wiring (F3, pure)
//
// The pure seam F3's auto-clip hero (and F4's "Animate" path) keys off. A session is
// `clipReady` iff it has a `SessionMedia` VIDEO **and** HR present **and** a non-empty
// `ReelPlan` from the EXISTING ranker (`SessionHighlightInput` → `HighlightSelector` →
// `ReelPlanner`). All three must hold — a video with no HR, or HR with no rankable
// segment, is NOT clipReady (it still gets the photo/generated-hero fallback).
//
// PURE: Foundation + HighlightEngine only — NO AVFoundation/UIKit/SwiftUI. The ranking
// runs the platform-free `HRHighlightSelector` + `ReelPlanner` directly, so the predicate
// and top-segment selection are unit-testable with synthetic inputs and no device. The
// actual AVPlayer attach + card hero swap are the device edge (R2 / `Services/FeedClipPlayer`).

/// A plain-value reference to the top-ranked clip segment of a session — enough for the
/// inline hero to loop a time-range over the source asset, and for the F4 "Animate" offer.
/// `assetId` is the PHAsset `localIdentifier` (the engine `MediaItem.id`).
struct FeedClipRef: Codable, Sendable, Equatable {
    /// The source asset's PHAsset `localIdentifier`.
    var assetId: String
    /// Seconds into the source asset where the looped segment begins.
    var offsetSec: Double
    /// Length of the looped segment in seconds (0 for a photo still).
    var durationSec: Double

    init(assetId: String, offsetSec: Double, durationSec: Double) {
        self.assetId = assetId
        self.offsetSec = offsetSec
        self.durationSec = durationSec
    }
}

enum FeedClipEligibility {

    /// The pure `clipReady` predicate. True iff **all** hold: a video is present **and**
    /// HR is present **and** the ranker produced ≥1 rankable segment. Each missing input
    /// flips it false (truth-tabled). This is the exact seam F4's Animate path consumes.
    static func clipReady(hasVideo: Bool, hasHR: Bool, planSegmentCount: Int) -> Bool {
        hasVideo && hasHR && planSegmentCount >= 1
    }

    /// Run the EXISTING ranker over a session's HR + clips + duration and return the
    /// resulting `ReelPlan`. Pure: builds the engine `Workout` via `SessionHighlightInput`,
    /// scores with the platform-free selector, and plans with `ReelPlanner` — no AppModel,
    /// no AVFoundation. `selector`/`planner`/`config` default to the same defaults the
    /// flagship reel uses (HR-only selector, per-activity preset) but are injectable so a
    /// caller can pass `AppModel`'s tuned engine pieces without touching this file.
    ///
    /// - Parameters:
    ///   - hrSeries: the session's live HR (B2 `hrSeries`).
    ///   - clips: the session's tagged video/photo clips (B1 `SessionMedia`).
    ///   - duration: session duration in seconds.
    ///   - sport/category: routine activity hint (drives the per-activity preset).
    static func reelPlan(hrSeries: [HRPoint],
                         clips: [SessionHighlightInput.Clip],
                         duration: Double,
                         sport: SportTag? = nil,
                         category: ExerciseCategory? = nil,
                         selector: any HighlightSelector = HRHighlightSelector(),
                         planner: ReelPlanner = ReelPlanner(),
                         config: HighlightConfig? = nil) -> ReelPlan {
        let workout = SessionHighlightInput.makeWorkout(
            hrSeries: hrSeries, clips: clips, duration: duration,
            sport: sport, category: category)
        guard !workout.media.isEmpty else { return ReelPlan(segments: [], photoStill: planner.photoStill) }
        let cfg = config ?? .preset(for: workout.activity)
        let highlights = selector.select(workout: workout, config: cfg)
        return planner.plan(highlights: highlights, media: workout.media)
    }

    /// The plan's segment count — the third input to `clipReady`.
    static func planSegmentCount(_ plan: ReelPlan) -> Int { plan.segments.count }

    /// The top-ranked segment as a plain-value `FeedClipRef` (highest score), or `nil` when
    /// the plan is empty. This is the segment the inline hero loops + the F4 Animate path
    /// would feature. Segments are scored; the top is the max-score one.
    static func topClipRef(_ plan: ReelPlan) -> FeedClipRef? {
        guard let top = plan.segments.max(by: { $0.score < $1.score }) else { return nil }
        return FeedClipRef(assetId: top.mediaItemId,
                           offsetSec: top.startWithinMedia,
                           durationSec: top.duration)
    }

    /// Convenience: run the ranker once and return both the `clipReady` flag and the top
    /// clip ref, so a caller (FeedQuery) building per-session enrichment does one pass.
    /// `hasVideo` is derived from the clips; `hasHR` from a non-empty HR series.
    static func evaluate(hrSeries: [HRPoint],
                         clips: [SessionHighlightInput.Clip],
                         duration: Double,
                         sport: SportTag? = nil,
                         category: ExerciseCategory? = nil) -> (clipReady: Bool, topClip: FeedClipRef?) {
        let hasVideo = clips.contains(where: \.isVideo)
        let hasHR = !hrSeries.isEmpty
        // Only run the (cheap but non-trivial) ranker when the cheap gates already hold.
        guard hasVideo, hasHR else { return (false, nil) }
        let plan = reelPlan(hrSeries: hrSeries, clips: clips, duration: duration,
                            sport: sport, category: category)
        let ready = clipReady(hasVideo: hasVideo, hasHR: hasHR, planSegmentCount: plan.segments.count)
        return (ready, topClipRef(plan))
    }
}
