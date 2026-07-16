import XCTest
import HighlightEngine
@testable import Snappet

/// The per-clip trimmer's pure layer (reel editor redesign): trim bounds/clamping over the
/// source media, `Highlight` rebuilds, and the reel-timeline map that mirrors the exporter's
/// composition cursor. No AVFoundation, no simulator.
final class ReelTrimTests: XCTestCase {

    private func video(_ id: String, start: Double, duration: Double) -> MediaItem {
        MediaItem(id: id, kind: .video, startOffset: start, duration: duration)
    }

    private func highlight(_ id: String = "h1", media: String = "m1",
                           start: Double, end: Double, at: Double? = nil) -> Highlight {
        Highlight(id: id, mediaItemId: media, kind: .high,
                  atOffset: at ?? (start + end) / 2, clipStart: start, clipEnd: end, score: 0.8)
    }

    // MARK: bounds

    func testBoundsAreTheSourceVideoSpan() {
        let media = [video("m1", start: 100, duration: 34)]
        let h = highlight(start: 112, end: 122)
        XCTAssertEqual(ReelTrim.bounds(for: h, media: media), 100...134)
    }

    func testPhotosAndMissingMediaAreNotTrimmable() {
        let photo = MediaItem(id: "p1", kind: .photo, startOffset: 50, duration: 0)
        XCTAssertNil(ReelTrim.bounds(for: highlight(media: "p1", start: 50, end: 50), media: [photo]),
                     "a still has no timeline to trim")
        XCTAssertNil(ReelTrim.bounds(for: highlight(media: "gone", start: 0, end: 5), media: []),
                     "no media row → no bounds")
    }

    // MARK: clamp

    func testClampKeepsWindowInsideBounds() {
        XCTAssertEqual(ReelTrim.clamp(90...105, bounds: 100...134), 100...105)
        XCTAssertEqual(ReelTrim.clamp(130...140, bounds: 100...134), 130...134)
    }

    func testClampEnforcesMinLengthWithoutInverting() {
        // Handles dragged together: the window pushes, never inverts.
        let out = ReelTrim.clamp(120...120.2, bounds: 100...134)
        XCTAssertEqual(out.upperBound - out.lowerBound, ReelTrim.minLength, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(out.lowerBound, 100)
        XCTAssertLessThanOrEqual(out.upperBound, 134)
        // At the tail there's no room forward — the start yields back instead.
        let tail = ReelTrim.clamp(133.9...134, bounds: 100...134)
        XCTAssertEqual(tail, (134 - ReelTrim.minLength)...134)
    }

    func testClampOnASourceShorterThanMinLengthTrimsToTheSource() {
        let out = ReelTrim.clamp(0...10, bounds: 100...100.5)
        XCTAssertEqual(out, 100...100.5, "a 0.5s source can't satisfy the 1s minimum — it IS the window")
    }

    // MARK: apply

    func testApplyRebuildsOnlyTrimmedHighlightsAndClampsAtOffset() {
        let a = highlight("a", start: 110, end: 120, at: 118)
        let b = highlight("b", start: 130, end: 140, at: 135)
        let out = ReelTrim.apply(["a": 112...115], to: [a, b])

        XCTAssertEqual(out[0].clipStart, 112)
        XCTAssertEqual(out[0].clipEnd, 115)
        XCTAssertEqual(out[0].atOffset, 115, "the peak marker clamps inside the new window")
        XCTAssertEqual(out[0].id, "a", "identity survives — pins/order/feedback keep working")
        XCTAssertEqual(out[0].score, a.score)
        XCTAssertEqual(out[1], b, "untrimmed highlights pass through untouched")
    }

    func testApplyWithNoTrimsIsIdentity() {
        let hs = [highlight("a", start: 1, end: 2), highlight("b", start: 3, end: 4)]
        XCTAssertEqual(ReelTrim.apply([:], to: hs), hs)
    }

    // MARK: timeline map (mirrors the composition cursor)

    /// `ReelPlan.Segment`'s init is engine-internal — build plans through the REAL planner,
    /// which is more honest anyway: the map is tested over exactly what production produces.
    private func plan(_ pairs: [(h: Highlight, m: MediaItem)], photoStill: Double = 2) -> ReelPlan {
        ReelPlanner(targetDuration: nil, photoStill: photoStill)
            .plan(highlights: pairs.map(\.h), media: pairs.map(\.m))
    }

    func testTimelineMapCursorsPhotosAtStillAndSkipsSubRenderableVideos() {
        let built = plan([
            (highlight("h1", media: "m1", start: 0, end: 8, at: 4),
             video("m1", start: 0, duration: 20)),
            (highlight("hp", media: "p1", start: 30, end: 30, at: 30),
             MediaItem(id: "p1", kind: .photo, startOffset: 30, duration: 0)),   // photo → photoStill
            (highlight("h2", media: "m2", start: 45, end: 45.05, at: 45),
             video("m2", start: 40, duration: 10)),   // ≤0.1s — the exporter drops it
            (highlight("h3", media: "m3", start: 52, end: 56, at: 54),
             video("m3", start: 50, duration: 10)),
        ])
        let map = ReelTimelineMap(plan: built)

        XCTAssertEqual(map.entries.map(\.segmentID), ["h1", "hp", "h3"],
                       "the sub-renderable video never lands on the timeline")
        XCTAssertEqual(map.entries.map(\.start), [0, 8, 10])
        XCTAssertEqual(map.totalDuration, 14)
    }

    func testSegmentLookupAtTimeAndPlayFromHere() {
        let built = plan([
            (highlight("h1", media: "m1", start: 0, end: 8, at: 4),
             video("m1", start: 0, duration: 20)),
            (highlight("h2", media: "m2", start: 52, end: 56, at: 54),
             video("m2", start: 50, duration: 10)),
        ])
        let map = ReelTimelineMap(plan: built)

        XCTAssertEqual(map.segmentID(at: 0), "h1")
        XCTAssertEqual(map.segmentID(at: 7.9), "h1")
        XCTAssertEqual(map.segmentID(at: 8.1), "h2")
        XCTAssertEqual(map.segmentID(at: 99), "h2", "past the end sticks to the last segment")
        XCTAssertEqual(map.start(of: "h2"), 8)
        XCTAssertNil(map.start(of: "nope"))
        XCTAssertNil(ReelTimelineMap(plan: plan([])).segmentID(at: 0))
    }
}
