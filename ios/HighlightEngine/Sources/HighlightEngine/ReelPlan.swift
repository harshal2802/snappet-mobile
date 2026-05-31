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
    ///
    /// - pinnedIds: highlights the user explicitly kept (auto-generate-then-edit,
    ///   #60 §B). They are **budget-exempt** — every pinned highlight is always
    ///   included, even if they alone exceed `targetDuration`; the remaining budget
    ///   is then filled with the rest by score.
    /// - order: an explicit highlight-id order for the reel. When provided, segments
    ///   follow it (ids not listed fall to the end by `atOffset`); otherwise the reel
    ///   is chronological. Pin/order are *app* composition state — the engine never
    ///   sets them on `Highlight` (keeps algorithm output pure; see decisions.md).
    public func plan(
        highlights: [Highlight],
        media: [MediaItem],
        pinnedIds: Set<String> = [],
        order: [String]? = nil
    ) -> ReelPlan {
        let byId = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        func clipDuration(_ h: Highlight, _ m: MediaItem) -> Double {
            m.kind == .photo ? photoStill : max(0, h.clipEnd - h.clipStart)
        }

        var picked: [Highlight] = []
        var pickedIds = Set<String>()
        var budget = targetDuration

        // 1. Pinned first — always included, budget-exempt (still drawn down so the
        //    score-filled remainder respects whatever space is left).
        for h in highlights where pinnedIds.contains(h.id) {
            guard let m = byId[h.mediaItemId], clipDuration(h, m) > 0 else { continue }
            picked.append(h)
            pickedIds.insert(h.id)
            budget -= clipDuration(h, m)
        }

        // 2. Fill remaining budget with the rest by score (highest first).
        for h in highlights.sorted(by: { $0.score > $1.score }) {
            if pickedIds.contains(h.id) { continue }
            guard let m = byId[h.mediaItemId] else { continue }
            let dur = clipDuration(h, m)
            if dur <= 0 { continue }
            if budget - dur < 0 && !picked.isEmpty { continue }
            picked.append(h)
            pickedIds.insert(h.id)
            budget -= dur
            if budget <= 0 { break }
        }

        // 3. Order: explicit id order when given, else chronological by atOffset.
        let ordered: [Highlight]
        if let order {
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            ordered = picked.sorted { a, b in
                switch (rank[a.id], rank[b.id]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true            // listed ids come first
                case (nil, .some): return false
                case (nil, nil): return a.atOffset < b.atOffset
                }
            }
        } else {
            ordered = picked.sorted { $0.atOffset < $1.atOffset }   // chronological reel
        }

        let segments = ordered.compactMap { h -> ReelPlan.Segment? in
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
