import XCTest
@testable import Snappet

/// Unit tests for the **single source of truth** that maps a clip → its HR + video overlay (prompt 84):
/// the window/values/tile build, the one window-duration denominator, and the video-time → playhead
/// fraction mapping that the still poster, the inline player, and the fullscreen viewer all share.
final class ClipHROverlayTests: XCTestCase {

    private func clip(offset: Double = 0, dur: Double? = 6) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: dur,
                   exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "asset")
    }

    // MARK: make

    func testMakeReturnsNilWhenNoHRInWindow() {
        XCTAssertNil(ClipHROverlay.make(clip: clip(), hrSeries: [], maxHR: 190, restHR: 60))
    }

    func testMakeBuildsClipLocalWindowValuesAndScorebugTile() throws {
        let series = (8...18).map { HRPoint(t: Double($0), bpm: 120 + Double($0)) }   // around [10,16]
        let p = try XCTUnwrap(ClipHROverlay.make(clip: clip(offset: 10, dur: 6),
                                                 hrSeries: series, maxHR: 190, restHR: 60))
        XCTAssertEqual(p.values.durationSec, 6, accuracy: 0.0001)      // == windowDuration
        XCTAssertEqual(p.values.maxHR, 190)
        XCTAssertEqual(p.values.restHR, 60)
        XCTAssertFalse(p.values.samples.isEmpty)
        XCTAssertGreaterThanOrEqual(p.values.samples.map(\.t).min() ?? -1, 0)   // rebased to clip-local
        XCTAssertEqual(p.tile.template, .scorebug)                    // the ONE feed scorebug tile
    }

    func testTileOverrideUsesTheSavedStudioTile() throws {
        let series = (10...16).map { HRPoint(t: Double($0), bpm: 130) }
        let c = clip(offset: 10, dur: 6)
        // No override → the house-style scorebug.
        let def = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertEqual(def.tile.template, .scorebug)
        // Override → the passed (saved Studio) tile, e.g. a hero (WYSIWYG, prompt 89).
        let hero = HRTile.make(template: .hero)
        let ov = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil, tile: hero))
        XCTAssertEqual(ov.tile.template, .hero)
    }

    // MARK: windowDuration — one denominator for values + fraction

    func testWindowDuration() {
        XCTAssertEqual(ClipHROverlay.windowDuration(clip(dur: 8)), 8, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.windowDuration(clip(dur: nil)), FeedMedia.photoWindowSec, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.windowDuration(clip(dur: 0)), 0.1, accuracy: 0.0001)   // clamped > 0
    }

    // MARK: fraction — video time → 0…1 playhead, normalized against the CHART axis (maxT), not duration

    /// The playhead must align with where the chart/dot/BPM actually draw — `HRChartGeometry` normalizes by
    /// `maxT` (the last in-window sample's clip-local t), NOT `durationSec`. Sparse window: HR reaches
    /// clip-local t=5 in a 6s clip → fraction(2.5) must be 0.5 (2.5/5), not 0.417 (2.5/6).
    func testFractionAlignsWithChartMaxTNotDuration() throws {
        let series = (10...15).map { HRPoint(t: Double($0), bpm: 130) }   // session [10,15] → clip [10,16] → local 0…5
        let c = clip(offset: 10, dur: 6)
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertEqual(try XCTUnwrap(p.values.samples.map(\.t).max()), 5, accuracy: 0.0001)               // maxT = 5, not dur 6
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 2.5, clip: c, payload: p), 0.5, accuracy: 0.0001) // 2.5/5, NOT 2.5/6
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 5,   clip: c, payload: p), 1.0, accuracy: 0.0001) // end of HR data
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 5.7, clip: c, payload: p), 1.0, accuracy: 0.0001) // tail pins at end
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 8.5, clip: c, payload: p), 0.5, accuracy: 0.0001) // loop → folded 2.5
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: .nan, clip: c, payload: p), 0, accuracy: 0.0001)  // guarded
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: .infinity, clip: c, payload: p), 0, accuracy: 0.0001)
    }

    /// Dense window (samples reach the end → maxT == dur): the clean modulo/loop case.
    func testFractionLoopsCleanlyWhenSamplesReachWindowEnd() throws {
        let series = (10...16).map { HRPoint(t: Double($0), bpm: 130) }   // clip [10,16] → local 0…6, maxT == dur == 6
        let c = clip(offset: 10, dur: 6)
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertEqual(try XCTUnwrap(p.values.samples.map(\.t).max()), 6, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 3, clip: c, payload: p), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 6, clip: c, payload: p), 0, accuracy: 0.0001)   // wrap
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 9, clip: c, payload: p), 0.5, accuracy: 0.0001) // 2nd loop
    }
}
