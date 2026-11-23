import XCTest
@testable import Snappet

/// Unit tests for the **pure** studio timeline + animation math (no device): clip output
/// durations (photo / trimmed-video / speed), multi-clip placement with transition overlaps,
/// total duration, keyframe interpolation (hold-at-ends, eased segments), and ordering.
final class StudioGeometryTests: XCTestCase {

    private func video(_ order: Int, id: UUID = UUID(), trimStart: Double = 0,
                       trimEnd: Double? = nil, speed: Double = 1) -> TimelineClip {
        TimelineClip(id: id, sessionMediaID: nil, localIdentifier: "v\(order)", isPhoto: false,
                     order: order, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
    }
    private func photo(_ order: Int, id: UUID = UUID(), duration: Double = 3) -> TimelineClip {
        TimelineClip(id: id, sessionMediaID: nil, localIdentifier: "p\(order)", isPhoto: true,
                     order: order, photoDurationSec: duration)
    }

    // MARK: - clipOutputDuration

    func testPhotoDurationIsItsOwn() {
        XCTAssertEqual(StudioGeometry.clipOutputDuration(photo(0, duration: 4), sourceDuration: 999), 4)
    }

    func testVideoTrimmedSpan() {
        let c = video(0, trimStart: 2, trimEnd: 8)
        XCTAssertEqual(StudioGeometry.clipOutputDuration(c, sourceDuration: 10), 6, accuracy: 1e-9)
    }

    func testVideoFullSourceWhenNoTrimEnd() {
        XCTAssertEqual(StudioGeometry.clipOutputDuration(video(0), sourceDuration: 12), 12, accuracy: 1e-9)
    }

    func testSpeedScalesDuration() {
        let c = video(0, trimStart: 0, trimEnd: 10, speed: 2)   // 2× → half as long
        XCTAssertEqual(StudioGeometry.clipOutputDuration(c, sourceDuration: 10), 5, accuracy: 1e-9)
    }

    func testTrimEndClampedToSource() {
        let c = video(0, trimStart: 0, trimEnd: 100)            // asks past the 10s source
        XCTAssertEqual(StudioGeometry.clipOutputDuration(c, sourceDuration: 10), 10, accuracy: 1e-9)
    }

    // MARK: - timeline placement

    func testEndToEndPlacementNoTransitions() {
        let a = video(0, trimEnd: 4), b = photo(1, duration: 3)
        let line = StudioGeometry.timeline(clips: [b, a],   // unsorted input
                                           sourceDurations: [a.id: 4], transitions: [])
        XCTAssertEqual(line.map(\.startSec), [0, 4])          // sorted by order, laid end-to-end
        XCTAssertEqual(line.map(\.durationSec), [4, 3])
        XCTAssertEqual(line.last?.endSec, 7)
    }

    func testTransitionPullsNextClipEarlier() {
        let a = video(0, trimEnd: 4), b = video(1, trimEnd: 4)
        let t = StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 1)
        let line = StudioGeometry.timeline(clips: [a, b],
                                           sourceDurations: [a.id: 4, b.id: 4], transitions: [t])
        XCTAssertEqual(line[0].startSec, 0)
        XCTAssertEqual(line[1].startSec, 3)                   // 4 − 1 overlap
        XCTAssertEqual(StudioGeometry.totalDuration(clips: [a, b],
                                                    sourceDurations: [a.id: 4, b.id: 4],
                                                    transitions: [t]), 7)   // 4 + 4 − 1
    }

    func testNoneTransitionIsHardCut() {
        let a = video(0, trimEnd: 4), b = video(1, trimEnd: 4)
        let t = StudioTransition(afterClipID: a.id, kind: .none, durationSec: 1)
        let line = StudioGeometry.timeline(clips: [a, b],
                                           sourceDurations: [a.id: 4, b.id: 4], transitions: [t])
        XCTAssertEqual(line[1].startSec, 4)                   // no overlap for a cut
    }

    func testOverlapClampedToShorterClip() {
        let a = video(0, trimEnd: 4), b = video(1, trimEnd: 1)   // next clip only 1s
        let t = StudioTransition(afterClipID: a.id, kind: .dissolve, durationSec: 3)
        let line = StudioGeometry.timeline(clips: [a, b],
                                           sourceDurations: [a.id: 4, b.id: 1], transitions: [t])
        XCTAssertEqual(line[1].startSec, 3)                   // overlap clamped to min(3,4,1)=1 → 4−1
    }

    // MARK: - keyframes

    func testEmptyKeyframesReturnDefault() {
        XCTAssertEqual(StudioGeometry.value(of: [], at: 5, default: 1.5), 1.5)
    }

    func testKeyframesHoldBeforeFirstAndAfterLast() {
        let ks = [StudioKeyframe(timeSec: 1, value: 10, easing: .linear),
                  StudioKeyframe(timeSec: 3, value: 30, easing: .linear)]
        XCTAssertEqual(StudioGeometry.value(of: ks, at: 0, default: 0), 10)   // before first
        XCTAssertEqual(StudioGeometry.value(of: ks, at: 9, default: 0), 30)   // after last
    }

    func testLinearMidpointInterpolation() {
        let ks = [StudioKeyframe(timeSec: 0, value: 0, easing: .linear),
                  StudioKeyframe(timeSec: 2, value: 100, easing: .linear)]
        XCTAssertEqual(StudioGeometry.value(of: ks, at: 1, default: 0), 50, accuracy: 1e-9)
    }

    func testEaseInOutMidpointIsHalf() {
        // easeInOut is symmetric → exactly 0.5 at the midpoint.
        let ks = [StudioKeyframe(timeSec: 0, value: 0, easing: .easeInOut),
                  StudioKeyframe(timeSec: 2, value: 100, easing: .easeInOut)]
        XCTAssertEqual(StudioGeometry.value(of: ks, at: 1, default: 0), 50, accuracy: 1e-9)
    }

    func testEaseInIsBelowLinearEarly() {
        XCTAssertLessThan(StudioGeometry.ease(0.25, .easeIn), 0.25)
        XCTAssertGreaterThan(StudioGeometry.ease(0.25, .easeOut), 0.25)
    }

    // MARK: - ordering & speed clamp

    func testOrderedIsDeterministicOnTies() {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let a = video(0, id: id2), b = video(0, id: id1)      // same order → tie broken by id
        XCTAssertEqual(StudioGeometry.ordered([a, b]).map(\.localIdentifier),
                       StudioGeometry.ordered([b, a]).map(\.localIdentifier))
        XCTAssertEqual(StudioGeometry.ordered([a, b]).first?.id, id1)
    }

    func testSpeedClampedInClipInit() {
        XCTAssertEqual(video(0, speed: 99).speed, 4.0)
        XCTAssertEqual(video(0, speed: 0.01).speed, 0.25)
    }

    // MARK: - filterByMedia (the per-clip / per-climb scope filter)

    private func mediaClip(_ order: Int, mediaID: UUID?) -> TimelineClip {
        TimelineClip(id: UUID(), sessionMediaID: mediaID, localIdentifier: "m\(order)",
                     isPhoto: false, order: order)
    }

    func testFilterByMediaNilPassesEverythingThrough() {
        let clips = [mediaClip(0, mediaID: UUID()), mediaClip(1, mediaID: nil)]
        XCTAssertEqual(StudioGeometry.filterByMedia(clips, to: nil).map(\.localIdentifier),
                       clips.map(\.localIdentifier))   // workout default: no scoping
    }

    func testFilterByMediaKeepsOnlyMatchingSessionMediaIDs() {
        let keep = UUID(), drop = UUID()
        let a = mediaClip(0, mediaID: keep), b = mediaClip(1, mediaID: drop)
        let result = StudioGeometry.filterByMedia([a, b], to: [keep])
        XCTAssertEqual(result.map(\.id), [a.id])        // only the in-scope clip survives
    }

    func testFilterByMediaExcludesClipsWithNoMediaIDWhenScoped() {
        let keep = UUID()
        let a = mediaClip(0, mediaID: keep), orphan = mediaClip(1, mediaID: nil)
        XCTAssertEqual(StudioGeometry.filterByMedia([a, orphan], to: [keep]).map(\.id), [a.id])
    }

    func testFilterByMediaSingleClipScopeIsJustThatClip() {
        let one = UUID(), two = UUID(), three = UUID()
        let clips = [mediaClip(0, mediaID: one), mediaClip(1, mediaID: two), mediaClip(2, mediaID: three)]
        XCTAssertEqual(StudioGeometry.filterByMedia(clips, to: [two]).map(\.sessionMediaID), [two])
    }

    // MARK: - reorderDestination (scope-correct clip reorder)

    func testReorderDestinationUnscopedIsIndexPlusDelta() {
        let a = video(0), b = video(1), c = video(2)
        let full = StudioGeometry.ordered([a, b, c])
        XCTAssertEqual(StudioGeometry.reorderDestination(id: b.id, by: 1, visible: full, full: full), 2)
        XCTAssertEqual(StudioGeometry.reorderDestination(id: b.id, by: -1, visible: full, full: full), 0)
    }

    func testReorderDestinationOffTheEndIsNil() {
        let a = video(0), b = video(1)
        let full = StudioGeometry.ordered([a, b])
        XCTAssertNil(StudioGeometry.reorderDestination(id: a.id, by: -1, visible: full, full: full))
        XCTAssertNil(StudioGeometry.reorderDestination(id: b.id, by: 1, visible: full, full: full))
    }

    func testReorderDestinationScopedMapsToFullIndex() {
        // Full order h0,v1,h2,v3 (h = hidden); visible subset v1,v3 (full indices 1 and 3).
        let h0 = video(0), v1 = video(1), h2 = video(2), v3 = video(3)
        let full = StudioGeometry.ordered([h0, v1, h2, v3])
        let visible = StudioGeometry.ordered([v1, v3])
        // Move v1 right one *visible* slot → v3's full index (3), not the scoped 1+1=2.
        XCTAssertEqual(StudioGeometry.reorderDestination(id: v1.id, by: 1, visible: visible, full: full), 3)
        // Move v3 left one *visible* slot → v1's full index (1).
        XCTAssertEqual(StudioGeometry.reorderDestination(id: v3.id, by: -1, visible: visible, full: full), 1)
        // Off the end of the visible subset → nil even though a full neighbor (h2) exists.
        XCTAssertNil(StudioGeometry.reorderDestination(id: v3.id, by: 1, visible: visible, full: full))
    }

    // MARK: - filterOverlays (scope overlays to the visible clips — prompt 13)

    private func mediaClip(_ order: Int, media: UUID) -> TimelineClip {
        TimelineClip(id: UUID(), sessionMediaID: media, localIdentifier: "m\(order)", isPhoto: false, order: order)
    }

    func testFilterOverlaysScopesToVisibleClipsKeepingGlobals() {
        let mediaA = UUID(), mediaB = UUID()
        let clipA = mediaClip(0, media: mediaA)
        let clipB = mediaClip(1, media: mediaB)
        let clips = [clipA, clipB]
        let tagA = OverlayItem(kind: .climbName, content: "A", clipID: clipA.id)
        let tagB = OverlayItem(kind: .climbName, content: "B", clipID: clipB.id)
        let global = OverlayItem(kind: .text, content: "G")   // clipID == nil → shows in every scope
        let all = [tagA, tagB, global]

        // Scope to clipA's media → only clipA's tag + the global overlay.
        XCTAssertEqual(Set(StudioGeometry.filterOverlays(all, clips: clips, to: [mediaA]).map(\.id)),
                       Set([tagA.id, global.id]))
        // Scope to clipB's media → only clipB's tag + the global overlay.
        XCTAssertEqual(Set(StudioGeometry.filterOverlays(all, clips: clips, to: [mediaB]).map(\.id)),
                       Set([tagB.id, global.id]))
        // No scope (whole-workout) → everything.
        XCTAssertEqual(StudioGeometry.filterOverlays(all, clips: clips, to: nil).count, 3)
    }

    func testFilterOverlaysDropsOrphanClipBoundOverlayWhenScoping() {
        let mediaA = UUID()
        let clipA = mediaClip(0, media: mediaA)
        let orphan = OverlayItem(kind: .climbName, content: "X", clipID: UUID())   // clip not present
        XCTAssertTrue(StudioGeometry.filterOverlays([orphan], clips: [clipA], to: [mediaA]).isEmpty)
        // …but it survives the unscoped view.
        XCTAssertEqual(StudioGeometry.filterOverlays([orphan], clips: [clipA], to: nil).count, 1)
    }

    // MARK: - overlay windows against the end of the timeline (prompt 297)

    /// A transition on the LAST clip has no next clip: the layout ignores it.
    func testTransitionOnTheLastClipDoesNotChangeTheLayout() {
        let a = video(0, trimEnd: 4), b = video(1, trimEnd: 6)
        let t = [StudioTransition(afterClipID: b.id, kind: .dissolve, durationSec: 1)]
        let placed = StudioGeometry.timeline(clips: [a, b], sourceDurations: [:], transitions: t)
        XCTAssertEqual(placed.map(\.startSec), [0, 4])
        XCTAssertEqual(StudioGeometry.totalDuration(clips: [a, b], sourceDurations: [:], transitions: t), 10)
    }

    func testClampedWindowCutsToTheTimeline() throws {
        // Inside → unchanged.
        var w = try XCTUnwrap(StudioGeometry.clampedWindow(start: 1, end: 3, total: 10))
        XCTAssertEqual(w.start, 1); XCTAssertEqual(w.end, 3)
        // Runs past the end → cut at the end.
        w = try XCTUnwrap(StudioGeometry.clampedWindow(start: 6, end: 14, total: 10))
        XCTAssertEqual(w.start, 6); XCTAssertEqual(w.end, 10)
        // Starts before zero → starts at zero.
        w = try XCTUnwrap(StudioGeometry.clampedWindow(start: -2, end: 3, total: 10))
        XCTAssertEqual(w.start, 0); XCTAssertEqual(w.end, 3)
    }

    func testClampedWindowDropsAWindowThatStartsAtOrAfterTheEnd() {
        XCTAssertNil(StudioGeometry.clampedWindow(start: 10, end: 12, total: 10))
        XCTAssertNil(StudioGeometry.clampedWindow(start: 11, end: 12, total: 10))
    }

    /// No clips, or durations not loaded: the length is not known, so nothing is cut or dropped.
    func testClampedWindowLeavesTheWindowAloneWhenTheLengthIsNotKnown() throws {
        for total in [nil, 0, -1] as [Double?] {
            let w = try XCTUnwrap(StudioGeometry.clampedWindow(start: 5, end: 9, total: total))
            XCTAssertEqual(w.start, 5); XCTAssertEqual(w.end, 9)
        }
    }

    func testClampedToTimelineCutsAndDropsOverlaysButKeepsTheRest() {
        let inside = OverlayItem(kind: .text, content: "in", startSec: 0, endSec: 3)
        let over = OverlayItem(kind: .video, content: "pip", startSec: 2, endSec: 30, opacity: 0.5)
        let after = OverlayItem(kind: .sticker, content: "star", startSec: 8, endSec: 9)
        let out = StudioGeometry.clampedToTimeline([inside, over, after], total: 5)
        XCTAssertEqual(out.map(\.id), [inside.id, over.id])          // the one after the end is left out
        XCTAssertEqual(out[0], inside)                               // untouched
        XCTAssertEqual(out[1].startSec, 2); XCTAssertEqual(out[1].endSec, 5)
        var expected = over; expected.endSec = 5
        XCTAssertEqual(out[1], expected)                             // only the end changed
        // A longer timeline gives the whole window back: the input was never changed.
        XCTAssertEqual(StudioGeometry.clampedToTimeline([inside, over, after], total: 60),
                       [inside, over, after])
    }

    func testPlayedFraction() {
        XCTAssertEqual(StudioGeometry.playedFraction(start: 0, end: 4, total: 10), 1)
        XCTAssertEqual(StudioGeometry.playedFraction(start: 8, end: 12, total: 10), 0.5, accuracy: 1e-9)
        XCTAssertEqual(StudioGeometry.playedFraction(start: 10, end: 12, total: 10), 0)
        XCTAssertEqual(StudioGeometry.playedFraction(start: 8, end: 12, total: nil), 1)   // timed by its clip
        XCTAssertEqual(StudioGeometry.playedFraction(start: 8, end: 12, total: 0), 1)     // length not known
    }

    func testOverlayMoveKeepsLengthAndStaysOnTheTimeline() {
        // A plain move.
        var w = StudioGeometry.overlayWindow(dragging: .move, bySeconds: 2, start: 1, end: 4, total: 10)
        XCTAssertEqual(w.start, 3); XCTAssertEqual(w.end, 6)
        // Before zero → starts at zero, same length.
        w = StudioGeometry.overlayWindow(dragging: .move, bySeconds: -5, start: 1, end: 4, total: 10)
        XCTAssertEqual(w.start, 0); XCTAssertEqual(w.end, 3)
        // Far past the end → the minimum stays inside; the length is kept (the rest is cut at render).
        w = StudioGeometry.overlayWindow(dragging: .move, bySeconds: 50, start: 1, end: 4, total: 10)
        XCTAssertEqual(w.start, 10 - StudioGeometry.minOverlayWindowSec, accuracy: 1e-9)
        XCTAssertEqual(w.end - w.start, 3, accuracy: 1e-9)
        // Length not known → only the zero limit.
        w = StudioGeometry.overlayWindow(dragging: .move, bySeconds: 50, start: 1, end: 4, total: nil)
        XCTAssertEqual(w.start, 51); XCTAssertEqual(w.end, 54)
    }

    func testOverlayTrailingEdgeStopsAtTheEndOfTheTimeline() {
        // Dragged later, past the end → stops at the end.
        var w = StudioGeometry.overlayWindow(dragging: .trailingEdge, bySeconds: 9, start: 2, end: 6, total: 10)
        XCTAssertEqual(w.start, 2); XCTAssertEqual(w.end, 10)
        // Already past the end (the timeline was shortened): a drag later does not pull it back…
        w = StudioGeometry.overlayWindow(dragging: .trailingEdge, bySeconds: 1, start: 2, end: 14, total: 10)
        XCTAssertEqual(w.end, 14)
        // …and a drag earlier moves it by what was dragged.
        w = StudioGeometry.overlayWindow(dragging: .trailingEdge, bySeconds: -6, start: 2, end: 14, total: 10)
        XCTAssertEqual(w.end, 8)
        // Length not known → no limit.
        w = StudioGeometry.overlayWindow(dragging: .trailingEdge, bySeconds: 9, start: 2, end: 6, total: nil)
        XCTAssertEqual(w.end, 15)
    }

    func testOverlayLeadingEdgeStaysOnTheTimeline() {
        var w = StudioGeometry.overlayWindow(dragging: .leadingEdge, bySeconds: -5, start: 2, end: 6, total: 10)
        XCTAssertEqual(w.start, 0); XCTAssertEqual(w.end, 6)
        w = StudioGeometry.overlayWindow(dragging: .leadingEdge, bySeconds: 1, start: 12, end: 14, total: 10)
        XCTAssertEqual(w.start, 10 - StudioGeometry.minOverlayWindowSec, accuracy: 1e-9)
        XCTAssertEqual(w.end, 14)
    }
}
