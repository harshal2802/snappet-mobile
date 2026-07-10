import XCTest
@testable import Snappet

/// Unit tests for the **single source of truth** that maps a clip → its HR + video overlay (prompt 84,
/// extended by prompt 116): the window/values/tile build, the played-range denominator, and the
/// video-time → playhead fraction mapping that the still poster, the inline player, and the fullscreen
/// viewer all share — now honouring the clip's Studio edit (trim + extended HR window + scope).
final class ClipHROverlayTests: XCTestCase {

    /// The pre-116 identity edit: no trim, no lead/tail — footage-only behaviour, byte-compatible with
    /// the original contract these tests pinned.
    private let zeroWindow = ClipStudioEdit(hrLeadSec: 0, hrTailSec: 0)

    private func clip(offset: Double = 0, dur: Double? = 6, edit: ClipStudioEdit? = nil) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: dur,
                   exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "asset", edit: edit)
    }

    // MARK: make

    func testMakeReturnsNilWhenNoHRInWindow() {
        XCTAssertNil(ClipHROverlay.make(clip: clip(), hrSeries: [], maxHR: 190, restHR: 60))
    }

    /// A PHOTO never gets the HR overlay — even with HR squarely inside its window — because a still is a
    /// single instant, not a span of effort, and there's no playhead to track. The SAME window + HR on a
    /// VIDEO does build a payload, proving it's the photo *kind* (not missing data) that suppresses it.
    func testMakeReturnsNilForPhotosEvenWithHR() {
        let series = (8...18).map { HRPoint(t: Double($0), bpm: 120 + Double($0)) }   // covers [10,16]
        let photo = MediaInput(id: UUID(), kind: "photo", offsetSec: 10, durationSec: nil,
                               exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "asset")
        XCTAssertNil(ClipHROverlay.make(clip: photo, hrSeries: series, maxHR: 190, restHR: 60))
        // Control: a video over the same window/HR still builds an overlay.
        XCTAssertNotNil(ClipHROverlay.make(clip: clip(offset: 10, dur: 6), hrSeries: series,
                                           maxHR: 190, restHR: 60))
    }

    func testMakeBuildsClipLocalWindowValuesAndScorebugTile() throws {
        let series = (8...18).map { HRPoint(t: Double($0), bpm: 120 + Double($0)) }   // around [10,16]
        let p = try XCTUnwrap(ClipHROverlay.make(clip: clip(offset: 10, dur: 6, edit: zeroWindow),
                                                 hrSeries: series, maxHR: 190, restHR: 60))
        XCTAssertEqual(p.values.durationSec, 6, accuracy: 0.0001)      // window span == footage (0/0 edit)
        XCTAssertEqual(p.values.maxHR, 190)
        XCTAssertEqual(p.values.restHR, 60)
        XCTAssertFalse(p.values.samples.isEmpty)
        XCTAssertGreaterThanOrEqual(p.values.samples.map(\.t).min() ?? -1, 0)   // rebased to window-local
        XCTAssertEqual(p.values.window?.isExtended, false)             // 0/0 = the pre-116 identity
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

    // MARK: playedRange — one denominator for the loop fold + video-fraction mapping (prompt 116)

    func testPlayedRange() {
        XCTAssertEqual(ClipHROverlay.playedRange(clip(dur: 8)).span, 8, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.playedRange(clip(dur: 8)).start, 0, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.playedRange(clip(dur: nil)).span, FeedMedia.photoWindowSec, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.playedRange(clip(dur: 0)).span, 0.1, accuracy: 0.0001)   // clamped > 0
        // A Studio trim: the feed plays the kept range.
        let trimmed = clip(dur: 41, edit: ClipStudioEdit(trimStart: 8, trimEnd: 31))
        XCTAssertEqual(ClipHROverlay.playedRange(trimmed).start, 8, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.playedRange(trimmed).span, 23, accuracy: 0.0001)
        // A degenerate trim (< minKeptSec) plays RAW.
        let blink = clip(dur: 41, edit: ClipStudioEdit(trimStart: 8, trimEnd: 8.2))
        XCTAssertEqual(ClipHROverlay.playedRange(blink).start, 0, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.playedRange(blink).span, 41, accuracy: 0.0001)
    }

    // MARK: fraction — video time → 0…1 playhead, normalized against the CHART axis (maxT), not duration

    /// The playhead must align with where the chart/dot/BPM actually draw — normalization is by
    /// `maxT` (the last in-window sample's window-local t), NOT `durationSec`. Sparse window: HR reaches
    /// clip-local t=5 in a 6s clip → fraction(2.5) must be 0.5 (2.5/5), not 0.417 (2.5/6).
    func testFractionAlignsWithChartMaxTNotDuration() throws {
        let series = (10...15).map { HRPoint(t: Double($0), bpm: 130) }   // session [10,15] → clip [10,16] → local 0…5
        let c = clip(offset: 10, dur: 6, edit: zeroWindow)
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertEqual(try XCTUnwrap(p.values.samples.map(\.t).max()), 5, accuracy: 0.0001)               // maxT = 5, not dur 6
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 2.5, clip: c, payload: p), 0.5, accuracy: 0.0001) // 2.5/5, NOT 2.5/6
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 5,   clip: c, payload: p), 1.0, accuracy: 0.0001) // end of HR data
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 5.7, clip: c, payload: p), 1.0, accuracy: 0.0001) // tail pins at end
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 8.5, clip: c, payload: p), 0.5, accuracy: 0.0001) // loop → folded 2.5
        // Non-finite time parks at the at-rest reading (what a non-playing surface shows) — prompt 116
        // changed this from 0 so a glitched read can't snap the dot to the window start.
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: .nan, clip: c, payload: p),
                       ClipHROverlay.atEnd(for: p), accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: .infinity, clip: c, payload: p),
                       ClipHROverlay.atEnd(for: p), accuracy: 0.0001)
    }

    /// Regression (prompt 91): a window overlapping just ONE session sample used to collapse to a single
    /// clip-local-`t=0` point → `maxT = 0` → `fraction` returned 0 → the dot **froze at the start** and
    /// the curve (needs ≥2 points) vanished. Routed through `HRWindowSlicer`, a single overlapping sample
    /// now yields a ≥2-point flat line spanning `[0, span]` (maxT == span), so the overlay draws and the
    /// playhead sweeps the whole clip in step with the video.
    func testSingleSampleWindowStillTracksTheVideo() throws {
        let series = [HRPoint(t: 12, bpm: 140)]              // one sample, inside the [10,16] window
        let c = clip(offset: 10, dur: 6, edit: zeroWindow)
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertGreaterThanOrEqual(p.values.samples.count, 2)                          // no single-point collapse
        XCTAssertEqual(try XCTUnwrap(p.values.samples.map(\.t).max()), 6, accuracy: 0.0001)  // maxT == span (not 0)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 0, clip: c, payload: p), 0, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 3, clip: c, payload: p), 0.5, accuracy: 0.0001)  // sweeps
    }

    /// Dense window (samples reach the end → maxT == dur): the clean modulo/loop case.
    func testFractionLoopsCleanlyWhenSamplesReachWindowEnd() throws {
        let series = (10...16).map { HRPoint(t: Double($0), bpm: 130) }   // clip [10,16] → local 0…6, maxT == dur == 6
        let c = clip(offset: 10, dur: 6, edit: zeroWindow)
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertEqual(try XCTUnwrap(p.values.samples.map(\.t).max()), 6, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 3, clip: c, payload: p), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 6, clip: c, payload: p), 0, accuracy: 0.0001)   // wrap
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 9, clip: c, payload: p), 0.5, accuracy: 0.0001) // 2nd loop
    }

    // MARK: Extended window in the feed (prompt 116 — convergence with the Studio/export)

    /// A clip with NO Studio edit gets the SAME default window the Studio would apply (lead 0:05 ·
    /// tail 0:30): the chart spans it, the dot enters at the lead boundary, sweeps only the footage,
    /// and the at-rest reading parks at the footage/tail boundary — never the tail end.
    func testDefaultWindowExtendsChartAndConfinesPlayhead() throws {
        let series = stride(from: 0.0, through: 120.0, by: 1.0).map { HRPoint(t: $0, bpm: 100 + $0 / 2) }
        let c = clip(offset: 40, dur: 30)                                 // edit nil → defaults
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        let w = try XCTUnwrap(p.values.window)
        XCTAssertEqual(w, HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 30))
        XCTAssertEqual(try XCTUnwrap(p.values.samples.map(\.t).max()), 65, accuracy: 0.01)  // full coverage
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 0, clip: c, payload: p), 5.0 / 65, accuracy: 0.001)
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 30, clip: c, payload: p, loops: false),
                       35.0 / 65, accuracy: 0.001)
        XCTAssertEqual(ClipHROverlay.atEnd(for: p), 35.0 / 65, accuracy: 0.001)   // parks at the boundary
    }

    /// A Studio-trimmed clip: the HR footage-span is the KEPT range (which the feed also plays), and
    /// asset-time video positions map through the kept-range offset — dot in sync with trimmed playback.
    func testTrimmedClipMapsKeptRangeOntoChart() throws {
        let series = stride(from: 0.0, through: 200.0, by: 1.0).map { HRPoint(t: $0, bpm: 110 + $0 / 4) }
        let edit = ClipStudioEdit(trimStart: 8, trimEnd: 31)              // kept 23s of a 41s clip
        let c = clip(offset: 60, dur: 41, edit: edit)
        let p = try XCTUnwrap(ClipHROverlay.make(clip: c, hrSeries: series, maxHR: 190, restHR: nil))
        let w = try XCTUnwrap(p.values.window)
        XCTAssertEqual(w.footageSec, 23, accuracy: 0.0001)                // trimmed footage, not raw 41
        XCTAssertEqual(w.leadSec, 5, accuracy: 0.0001)
        let maxT = try XCTUnwrap(p.values.samples.map(\.t).max())        // 5 + 23 + 30 = 58 (full coverage)
        XCTAssertEqual(maxT, 58, accuracy: 0.01)
        // Asset time 8 (= kept start) → video fraction 0 → the lead boundary.
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 8, clip: c, payload: p), 5.0 / 58, accuracy: 0.001)
        // Asset time 31 (= kept end, non-looping) → the footage/tail boundary.
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 31, clip: c, payload: p, loops: false),
                       28.0 / 58, accuracy: 0.001)
        // Looping: the kept span folds — asset time 8 + 23 lands back at the lead boundary.
        XCTAssertEqual(ClipHROverlay.fraction(videoTime: 31, clip: c, payload: p, loops: true),
                       5.0 / 58, accuracy: 0.001)
    }

    /// Metrics scope flows into the feed values: `.clip` restricts PEAK to the footage; the default
    /// `.window` includes the off-camera tail spike (the feature's whole point).
    func testMetricsScopeFlowsIntoFeedValues() throws {
        // bpm: 120 across the footage [40,70], spiking to 180 in the tail (t=80).
        let series = stride(from: 0.0, through: 120.0, by: 1.0).map { t in
            HRPoint(t: t, bpm: t > 75 && t < 85 ? 180 : 120)
        }
        let windowScoped = try XCTUnwrap(ClipHROverlay.make(
            clip: clip(offset: 40, dur: 30), hrSeries: series, maxHR: 190, restHR: nil))
        let clipScoped = try XCTUnwrap(ClipHROverlay.make(
            clip: clip(offset: 40, dur: 30, edit: ClipStudioEdit(hrMetricsScope: .clip)),
            hrSeries: series, maxHR: 190, restHR: nil))
        XCTAssertEqual(windowScoped.values.staticValue(.maxHR, fallbackHex: "#FFF")?.value, "180")
        XCTAssertEqual(clipScoped.values.staticValue(.maxHR, fallbackHex: "#FFF")?.value, "120")
    }
}
