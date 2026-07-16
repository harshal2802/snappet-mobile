import Foundation
import HighlightEngine

// MARK: - Per-clip trim + reel-timeline mapping (reel editor redesign)
//
// The engine anticipated a trimmer (`Highlight.clipStartWithin` — "what a trimmer needs") but
// never got one: the auto-cut window was final. These pure helpers let the clip sheet drag a
// highlight's window anywhere inside its source video, then rebuild the `Highlight` values the
// planner consumes — the engine itself is UNTOUCHED, and because `buildPreview` and `export`
// both plan from the trimmed highlights, what you drag is what ships.
//
// Foundation + engine value types only — unit-tested in `ReelTrimTests` with no simulator.

enum ReelTrim {
    /// The shortest a trimmed clip may get — below this a cut reads as a glitch, and the
    /// exporter drops ≤0.1s segments outright.
    static let minLength: Double = 1.0

    /// The window a highlight's trim may move within: its source VIDEO's full span on the
    /// workout timeline. `nil` = not trimmable (photo — a still has no timeline; or the media
    /// row is gone).
    static func bounds(for h: Highlight, media: [MediaItem]) -> ClosedRange<Double>? {
        guard let m = media.first(where: { $0.id == h.mediaItemId }),
              m.kind == .video, m.duration > 0 else { return nil }
        return m.startOffset...(m.startOffset + m.duration)
    }

    /// Clamp a proposed trim into `bounds`, keeping at least `minLength` seconds. Each edge
    /// clamps independently (a window poking out of bounds is CUT to them, never slid — the
    /// untouched edge stays put); if that leaves less than the minimum, the end extends
    /// forward first and the start yields back when the tail has no room — so a handle
    /// dragged past the other pushes, never inverts.
    static func clamp(_ proposed: ClosedRange<Double>, bounds: ClosedRange<Double>,
                      minLength: Double = ReelTrim.minLength) -> ClosedRange<Double> {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return bounds }
        let min = Swift.min(minLength, span)   // a source shorter than minLength trims to itself
        var start = proposed.lowerBound.clamped(to: bounds)
        var end = Swift.max(start, proposed.upperBound.clamped(to: bounds))
        if end - start < min {
            end = Swift.min(bounds.upperBound, start + min)
            start = Swift.min(start, end - min)
        }
        return start...end
    }

    /// Rebuild highlights with their user trims applied (identity for un-trimmed ids). The
    /// peak marker (`atOffset`) is clamped inside the new window so downstream consumers
    /// (intensity badges, feedback logging) stay coherent.
    static func apply(_ trims: [String: ClosedRange<Double>], to highlights: [Highlight]) -> [Highlight] {
        guard !trims.isEmpty else { return highlights }
        return highlights.map { h in
            guard let t = trims[h.id] else { return h }
            return Highlight(id: h.id, mediaItemId: h.mediaItemId, kind: h.kind,
                             atOffset: h.atOffset.clamped(to: t),
                             clipStart: t.lowerBound, clipEnd: t.upperBound, score: h.score)
        }
    }
}

/// Where each plan segment starts on the STITCHED reel timeline — mirrors
/// `ReelExporter.makeComposition`'s cursor (photos advance `photoStill`; videos their segment
/// duration; ≤0.1s video segments are dropped from the composition, so they're skipped here
/// too). Unreadable-asset skips inside the exporter can drift this map; its consumers (the
/// filmstrip's current-frame ring, "Play from here") are cosmetic, so best-effort is correct.
struct ReelTimelineMap {
    struct Entry: Equatable {
        let segmentID: String
        let start: Double
        let duration: Double
    }
    let entries: [Entry]
    var totalDuration: Double { entries.last.map { $0.start + $0.duration } ?? 0 }

    init(plan: ReelPlan) {
        var cursor = 0.0
        var out: [Entry] = []
        for seg in plan.segments {
            let dur: Double
            if seg.kind == .photo {
                dur = plan.photoStill
            } else if seg.duration > 0.1 {
                dur = seg.duration
            } else {
                continue   // the exporter's `renderable` filter drops it — never on the timeline
            }
            out.append(Entry(segmentID: seg.id, start: cursor, duration: dur))
            cursor += dur
        }
        entries = out
    }

    /// The segment playing at `time` (the filmstrip's ring). Past-the-end sticks to the last
    /// segment so the ring doesn't vanish on the final frame.
    func segmentID(at time: Double) -> String? {
        guard !entries.isEmpty else { return nil }
        return entries.last(where: { $0.start <= time })?.segmentID ?? entries.first?.segmentID
    }

    /// Where to seek for "Play from here" on a given segment id.
    func start(of segmentID: String) -> Double? {
        entries.first(where: { $0.segmentID == segmentID })?.start
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
