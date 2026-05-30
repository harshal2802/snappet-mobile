import Foundation

/// Top-level façade: workout in → highlights + reel plan out. This is the one type
/// the app talks to; everything behind it (selector, config, planner) is swappable.
public struct HighlightEngine: Sendable {
    public var selector: any HighlightSelector
    public var planner: ReelPlanner
    public var feedback: FeedbackSink

    public init(
        selector: any HighlightSelector = HRHighlightSelector(),
        planner: ReelPlanner = ReelPlanner(),
        feedback: FeedbackSink = NullFeedbackSink()
    ) {
        self.selector = selector
        self.planner = planner
        self.feedback = feedback
    }

    public struct Result: Sendable {
        public let highlights: [Highlight]
        public let reel: ReelPlan
        public let config: HighlightConfig
        public let selectorName: String
    }

    /// Generate highlights + a default reel for a workout.
    /// - config: pass nil to use the per-activity preset (best-guess defaults).
    public func generate(for workout: Workout, config: HighlightConfig? = nil) -> Result {
        let cfg = config ?? .preset(for: workout.activity)
        let highlights = selector.select(workout: workout, config: cfg)
        let reel = planner.plan(highlights: highlights, media: workout.media)
        return Result(highlights: highlights, reel: reel, config: cfg,
                      selectorName: String(describing: type(of: selector)))
    }

    /// Convenience for logging "shown" feedback for an auto-generated set.
    public func logShown(_ result: Result, workoutId: String, activity: Activity, now: Double) {
        for h in result.highlights {
            feedback.record(.init(
                workoutId: workoutId, activity: activity, action: .shown,
                atOffset: h.atOffset, score: h.score, highlightKind: h.kind,
                selectorName: result.selectorName, configFingerprint: result.config.fingerprint,
                timestamp: now
            ))
        }
    }
}
