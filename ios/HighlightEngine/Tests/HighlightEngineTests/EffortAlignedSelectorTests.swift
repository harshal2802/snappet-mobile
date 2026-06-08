import XCTest
@testable import HighlightEngine

final class EffortAlignedSelectorTests: XCTestCase {

    // Minimal fixtures — EffortAlignedSelector only reads `offset` + its windows, so the workout/hr
    // content is irrelevant; these just satisfy the protocol signature.
    private let workout = Workout(activity: .climbing, duration: 300, hr: [], restBpm: 60, maxBpm: 190, media: [])
    private let hr = HeartRateSeries.make(from: [HRSample(t: 0, bpm: 120)], duration: 300,
                                          smoothingWindowSec: 5, restBpm: 60, maxBpm: 190)
    private let cfg = HighlightConfig.preset(for: .climbing)

    func testBoostsInsideWindowOnly() {
        let sel = EffortAlignedSelector(windows: [100...130], boost: 1.0)
        XCTAssertEqual(sel.score(at: 115, workout: workout, hr: hr, config: cfg), 1.0)   // inside
        XCTAssertEqual(sel.score(at: 50, workout: workout, hr: hr, config: cfg), 0)       // outside
        XCTAssertEqual(sel.score(at: 200, workout: workout, hr: hr, config: cfg), 0)      // outside
    }

    func testEmptyWindowsScoreZero() {
        let sel = EffortAlignedSelector(windows: [])
        XCTAssertEqual(sel.score(at: 115, workout: workout, hr: hr, config: cfg), 0)
    }

    func testFusionRaisesInWindowAboveOutWindow() {
        // Same HR everywhere (flat series) → HR contributes equally; the effort boost must tip the
        // in-window offset above the out-window one.
        let fusion = FusionSelector.effortAligned(windows: [100...130])
        let inWin = fusion.score(at: 115, workout: workout, hr: hr, config: cfg)
        let outWin = fusion.score(at: 200, workout: workout, hr: hr, config: cfg)
        XCTAssertGreaterThan(inWin, outWin)
    }

    func testEmptyWindowFusionEqualsHROnly() {
        // No achievement windows ⇒ the effort part is 0 everywhere ⇒ fusion ranks purely on HR
        // (gated: no behavior change without windows).
        let fusion = FusionSelector.effortAligned(windows: [])
        let hrOnly = HRHighlightSelector()
        let a = fusion.score(at: 115, workout: workout, hr: hr, config: cfg)
        let b = 0.6 * hrOnly.score(at: 115, workout: workout, hr: hr, config: cfg)
        XCTAssertEqual(a, b, accuracy: 0.0001)
    }
}
