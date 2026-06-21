import XCTest
import HighlightEngine
@testable import Snappet

/// F3 (R1) — `clipReady` truth table + the ReelPlan-segment-count ranking wiring.
/// Pure: no device, no AVFoundation; the ranker runs the platform-free selector/planner.
final class FeedClipEligibilityTests: XCTestCase {

    // MARK: - clipReady truth table

    func testClipReadyAllPresentIsTrue() {
        XCTAssertTrue(FeedClipEligibility.clipReady(hasVideo: true, hasHR: true, planSegmentCount: 1))
        XCTAssertTrue(FeedClipEligibility.clipReady(hasVideo: true, hasHR: true, planSegmentCount: 5))
    }

    func testClipReadyEachMissingInputIsFalse() {
        XCTAssertFalse(FeedClipEligibility.clipReady(hasVideo: false, hasHR: true, planSegmentCount: 1),
                       "no video → not clipReady")
        XCTAssertFalse(FeedClipEligibility.clipReady(hasVideo: true, hasHR: false, planSegmentCount: 1),
                       "no HR → not clipReady")
        XCTAssertFalse(FeedClipEligibility.clipReady(hasVideo: true, hasHR: true, planSegmentCount: 0),
                       "no rankable segment → not clipReady")
        XCTAssertFalse(FeedClipEligibility.clipReady(hasVideo: false, hasHR: false, planSegmentCount: 0),
                       "nothing present → not clipReady")
    }

    func testClipReadyFullTruthTable() {
        // Only (true, true, >=1) is true; every other combination is false.
        for v in [false, true] {
            for h in [false, true] {
                for n in [0, 1, 3] {
                    let expected = v && h && n >= 1
                    XCTAssertEqual(FeedClipEligibility.clipReady(hasVideo: v, hasHR: h, planSegmentCount: n),
                                   expected, "v=\(v) h=\(h) n=\(n)")
                }
            }
        }
    }

    // MARK: - ReelPlan ranking wiring

    /// Synthetic rising-then-falling HR over a single tagged video → the ranker must produce
    /// ≥1 segment, and `evaluate` reports clipReady with a top clip pointing at the video.
    func testReelPlanProducesSegmentsOverSyntheticClipAndHR() {
        let hr = syntheticHR(durationSec: 60, base: 90, peakAt: 30, peak: 175)
        let clips = [SessionHighlightInput.Clip(localIdentifier: "asset-1", isVideo: true, offsetSec: 10, durationSec: 20)]
        let plan = FeedClipEligibility.reelPlan(hrSeries: hr, clips: clips, duration: 60)
        XCTAssertGreaterThanOrEqual(plan.segments.count, 1, "a tagged video + HR must yield a rankable segment")
        XCTAssertEqual(FeedClipEligibility.planSegmentCount(plan), plan.segments.count)

        let top = FeedClipEligibility.topClipRef(plan)
        XCTAssertNotNil(top)
        XCTAssertEqual(top?.assetId, "asset-1", "the top segment comes from the only tagged clip")
    }

    func testEvaluateClipReadyWhenVideoPlusHRPlusPlan() {
        let hr = syntheticHR(durationSec: 60, base: 90, peakAt: 30, peak: 175)
        let clips = [SessionHighlightInput.Clip(localIdentifier: "asset-1", isVideo: true, offsetSec: 10, durationSec: 20)]
        let result = FeedClipEligibility.evaluate(hrSeries: hr, clips: clips, duration: 60)
        XCTAssertTrue(result.clipReady)
        XCTAssertNotNil(result.topClip)
        XCTAssertEqual(result.topClip?.assetId, "asset-1")
    }

    func testEvaluateNotClipReadyWithoutHR() {
        let clips = [SessionHighlightInput.Clip(localIdentifier: "asset-1", isVideo: true, offsetSec: 10, durationSec: 20)]
        let result = FeedClipEligibility.evaluate(hrSeries: [], clips: clips, duration: 60)
        XCTAssertFalse(result.clipReady, "video but no HR is not clipReady")
        XCTAssertNil(result.topClip)
    }

    func testEvaluateNotClipReadyWithoutVideo() {
        let hr = syntheticHR(durationSec: 60, base: 90, peakAt: 30, peak: 175)
        // A photo-only session has no video.
        let clips = [SessionHighlightInput.Clip(localIdentifier: "photo-1", isVideo: false, offsetSec: 10, durationSec: nil)]
        let result = FeedClipEligibility.evaluate(hrSeries: hr, clips: clips, duration: 60)
        XCTAssertFalse(result.clipReady, "HR but no video is not clipReady")
        XCTAssertNil(result.topClip)
    }

    func testReelPlanEmptyWhenNoMediaResolvable() {
        let hr = syntheticHR(durationSec: 60, base: 90, peakAt: 30, peak: 175)
        let plan = FeedClipEligibility.reelPlan(hrSeries: hr, clips: [], duration: 60)
        XCTAssertEqual(plan.segments.count, 0)
        XCTAssertNil(FeedClipEligibility.topClipRef(plan))
    }

    // MARK: - Helpers

    /// A triangular HR ramp: rises from `base` to `peak` at `peakAt` seconds, then falls back.
    private func syntheticHR(durationSec: Double, base: Double, peakAt: Double, peak: Double) -> [HRPoint] {
        stride(from: 0.0, through: durationSec, by: 1.0).map { t in
            let frac: Double
            if t <= peakAt {
                frac = peakAt > 0 ? t / peakAt : 1
            } else {
                let tail = max(1, durationSec - peakAt)
                frac = max(0, 1 - (t - peakAt) / tail)
            }
            return HRPoint(t: t, bpm: base + (peak - base) * frac)
        }
    }
}
