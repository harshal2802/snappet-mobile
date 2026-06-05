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
}
