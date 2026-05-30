import Foundation

/// A platform-free description of the reel to assemble: an ordered list of clip
/// segments (which media, which in-clip time range). The iOS layer turns this into
/// an `AVMutableComposition`; Android would turn it into a Media3 `Composition`.
/// Keeping it as data (not AVFoundation) is what makes the engine portable + testable.
public struct ReelPlan: Sendable, Equatable {
    public struct Segment: Sendable, Equatable, Identifiable {
        public let id: String
        public let mediaItemId: String
        public let kind: MediaItem.Kind
        public let startWithinMedia: Double   // seconds into the source media
        public let endWithinMedia: Double
        public let highlightKind: Highlight.Kind
        public let score: Double
        public var duration: Double { max(0, endWithinMedia - startWithinMedia) }
    }

    public let segments: [Segment]
    public var totalDuration: Double { segments.reduce(0) { $0 + max($1.duration, photoStill) } }
    public let photoStill: Double     // seconds a photo is shown for

    public init(segments: [Segment], photoStill: Double) {
        self.segments = segments
        self.photoStill = photoStill
    }
}

/// Turns ranked highlights into a concrete, length-bounded reel plan.
/// This is the "auto-generate-then-edit" default (Snappet#60 §B): produce a good
/// reel automatically; the app then lets the user reorder/remove/regenerate.
public struct ReelPlanner: Sendable {
    public var targetDuration: Double      // desired reel length (seconds)
    public var photoStill: Double          // how long each photo shows
    public init(targetDuration: Double = 30, photoStill: Double = 2.0) {
        self.targetDuration = targetDuration
        self.photoStill = photoStill
    }

    /// Build a reel from highlights (highest score first up to the target length),
    /// then present chronologically. `media` is needed to convert timeline offsets
    /// into in-media offsets.
    public func plan(highlights: [Highlight], media: [MediaItem]) -> ReelPlan {
        let byId = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        var budget = targetDuration
        var picked: [Highlight] = []
        for h in highlights.sorted(by: { $0.score > $1.score }) {
            guard let m = byId[h.mediaItemId] else { continue }
            let dur = m.kind == .photo ? photoStill : max(0, h.clipEnd - h.clipStart)
            if dur <= 0 { continue }
            if budget - dur < 0 && !picked.isEmpty { continue }
            picked.append(h)
            budget -= dur
            if budget <= 0 { break }
        }
        let segments = picked
            .sorted { $0.atOffset < $1.atOffset }      // chronological reel
            .compactMap { h -> ReelPlan.Segment? in
                guard let m = byId[h.mediaItemId] else { return nil }
                return ReelPlan.Segment(
                    id: h.id, mediaItemId: m.id, kind: m.kind,
                    startWithinMedia: max(0, h.clipStartWithin(m)),
                    endWithinMedia: m.kind == .photo ? 0 : max(0, h.clipEndWithin(m)),
                    highlightKind: h.kind, score: h.score
                )
            }
        return ReelPlan(segments: segments, photoStill: photoStill)
    }
}
