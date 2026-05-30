import Foundation

// MARK: - Core domain model
//
// Mirrors the "Snappet Core" schema (see the web repo's
// pdd/context/snappet-core-schema.md). These are the engine's *inputs and
// outputs* — deliberately platform-free so the algorithm is testable and reusable.

/// A single heart-rate sample. `t` is seconds from workout start (monotonic).
public struct HRSample: Sendable, Equatable {
    public let t: Double
    public let bpm: Double
    public init(t: Double, bpm: Double) {
        self.t = t
        self.bpm = bpm
    }
}

public enum Activity: String, Sendable, CaseIterable {
    case climbing, running, dance, strength, other
}

/// A photo/clip imported from the library, already matched to the workout window.
public struct MediaItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: Kind
    /// Capture time as seconds from workout start (already aligned — see TimeSync).
    public let startOffset: Double
    /// Duration in seconds (0 for photos).
    public let duration: Double

    public enum Kind: String, Sendable { case video, photo }

    public init(id: String, kind: Kind, startOffset: Double, duration: Double) {
        self.id = id
        self.kind = kind
        self.startOffset = startOffset
        self.duration = duration
    }

    /// Absolute end offset of the media on the workout timeline.
    public var endOffset: Double { startOffset + duration }
}

/// A scored highlight moment mapped onto a specific media item.
public struct Highlight: Sendable, Equatable, Identifiable {
    public let id: String
    public let mediaItemId: String
    public let kind: Kind
    /// The peak moment, in seconds from workout start.
    public let atOffset: Double
    /// Padded clip window on the workout timeline.
    public let clipStart: Double
    public let clipEnd: Double
    /// 0...1 intensity-derived rank score.
    public let score: Double

    public enum Kind: String, Sendable { case high, low }

    public init(id: String, mediaItemId: String, kind: Kind,
                atOffset: Double, clipStart: Double, clipEnd: Double, score: Double) {
        self.id = id
        self.mediaItemId = mediaItemId
        self.kind = kind
        self.atOffset = atOffset
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.score = score
    }

    /// Offset of the clip *within its media item* (what a trimmer needs).
    public func clipStartWithin(_ media: MediaItem) -> Double { clipStart - media.startOffset }
    public func clipEndWithin(_ media: MediaItem) -> Double { clipEnd - media.startOffset }
}

/// Everything the engine needs about one tracked session.
public struct Workout: Sendable {
    public let activity: Activity
    public let duration: Double            // seconds
    public let hr: [HRSample]              // authoritative, post-workout series
    public let restBpm: Double?            // for %HRR; estimated if nil
    public let maxBpm: Double?             // for %HRR; estimated if nil
    public let media: [MediaItem]

    public init(activity: Activity, duration: Double, hr: [HRSample],
                restBpm: Double? = nil, maxBpm: Double? = nil, media: [MediaItem]) {
        self.activity = activity
        self.duration = duration
        self.hr = hr
        self.restBpm = restBpm
        self.maxBpm = maxBpm
        self.media = media
    }
}
