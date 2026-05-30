import Foundation

/// Training-data capture — the whole reason to ship a "best guess" now.
///
/// Every time the auto-generated reel is shown and the user accepts/edits it, we log
/// what the engine proposed vs what the human actually kept. Replaying these events
/// later (offline) lets us tune `HighlightConfig`, learn the real HR-vs-content
/// weighting, and estimate `effort_mix` — turning the spike's NEEDS-REAL-DATA into a
/// data-driven GO. Pure Codable; the app persists these to Snappet Core / disk and
/// (with consent) can export them for analysis.
public struct HighlightFeedbackEvent: Sendable, Codable, Equatable {
    public enum Action: String, Sendable, Codable {
        case shown        // engine proposed this highlight in the auto reel
        case kept         // survived the user's edit
        case removed      // user deleted it
        case added        // user manually added a moment the engine missed
        case reordered    // user moved it
        case pinned       // user explicitly pinned (strong positive signal)
        case regenerated  // user asked for a fresh reel (weak negative on the whole set)
        case exported     // final reel exported/shared (strong positive on survivors)
    }

    public let workoutId: String
    public let activity: Activity
    public let action: Action
    /// Engine attribution for the moment (so we can correlate outcomes with signals).
    public let atOffset: Double?
    public let score: Double?
    public let highlightKind: Highlight.Kind?
    public let selectorName: String          // which selector produced it
    public let configFingerprint: String     // which params were in effect
    /// Seconds-from-epoch is supplied by the caller (engine stays clock-free/testable).
    public let timestamp: Double

    public init(workoutId: String, activity: Activity, action: Action,
                atOffset: Double? = nil, score: Double? = nil,
                highlightKind: Highlight.Kind? = nil,
                selectorName: String, configFingerprint: String, timestamp: Double) {
        self.workoutId = workoutId
        self.activity = activity
        self.action = action
        self.atOffset = atOffset
        self.score = score
        self.highlightKind = highlightKind
        self.selectorName = selectorName
        self.configFingerprint = configFingerprint
        self.timestamp = timestamp
    }
}

/// Where feedback events go. The app provides an implementation (file / Snappet Core
/// / export). Engine code depends only on this protocol, never on storage details.
public protocol FeedbackSink: Sendable {
    func record(_ event: HighlightFeedbackEvent)
}

/// A no-op sink for tests / when logging is disabled.
public struct NullFeedbackSink: FeedbackSink {
    public init() {}
    public func record(_ event: HighlightFeedbackEvent) {}
}

public extension HighlightConfig {
    /// Stable short fingerprint of the tunables, for attributing feedback to params.
    var fingerprint: String {
        "sm\(Int(smoothingWindowSec))_lag\(Int(hrLagSec))_l\(Int(wLevel*100))_s\(Int(wSlope*100))_g\(Int(minGapSec))"
    }
}
