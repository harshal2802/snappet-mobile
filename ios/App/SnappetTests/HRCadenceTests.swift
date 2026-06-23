import XCTest
@testable import Snappet

/// Tests for the pure `HRCadence` diagnostic (Phase A / M5): does it correctly measure how densely a
/// heart-rate series is sampled, and flag an interpolation-dominated clip window? This is the signal
/// Phase B's overlay uses to style sparse windows honestly.
final class HRCadenceTests: XCTestCase {

    private func series(_ ts: [Double]) -> [HRPoint] { ts.map { HRPoint(t: $0, bpm: 130) } }

    func testEmptyAndSingle() {
        XCTAssertEqual(HRCadence.summarize([]), .empty)
        let one = HRCadence.summarize(series([4]))
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.spanSec, 0)
        XCTAssertEqual(one.perSecond, 0)
        // < 2 samples is always "sparse" (nothing to interpolate between).
        XCTAssertTrue(one.isSparse(windowSec: 30))
    }

    func testDenseOneHzWindowIsNotSparse() {
        let c = HRCadence.summarize(series((0...30).map(Double.init)))   // 31 samples, 0…30s
        XCTAssertEqual(c.count, 31)
        XCTAssertEqual(c.spanSec, 30, accuracy: 1e-9)
        XCTAssertEqual(c.perSecond, 1.0, accuracy: 1e-9)                 // 30 intervals / 30s
        XCTAssertEqual(c.medianGapSec, 1, accuracy: 1e-9)
        XCTAssertEqual(c.maxGapSec, 1, accuracy: 1e-9)
        XCTAssertFalse(c.isSparse(windowSec: 30))
    }

    func testTwoPointsInThirtySecondsIsSparse() {
        // The reported symptom: two samples bracketing a 30s clip.
        let c = HRCadence.summarize(series([0, 30]))
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.perSecond, 1.0 / 30.0, accuracy: 1e-9)          // 1 interval / 30s ≈ 0.033 Hz
        XCTAssertEqual(c.maxGapSec, 30, accuracy: 1e-9)
        XCTAssertTrue(c.isSparse(windowSec: 30))                         // below 0.2 Hz AND one big hole
    }

    func testSingleLargeGapTripsMaxGapFraction() {
        // Reasonable overall count, but a single hole swallows most of the window.
        let c = HRCadence.summarize(series([0, 1, 2, 28, 29, 30]))
        XCTAssertEqual(c.maxGapSec, 26, accuracy: 1e-9)                  // the 2→28 hole
        XCTAssertTrue(c.isSparse(windowSec: 30))                         // 26 > 30 * 0.6
        // The same series in a much longer window is not gap-dominated.
        XCTAssertFalse(c.isSparse(windowSec: 120, minPerSecond: 0.0))
    }

    func testWatchCadenceEverySixSecondsIsSparse() {
        // ~0.17 Hz — the Apple-Watch live ceiling — is below the 0.2 Hz floor.
        let c = HRCadence.summarize(series(stride(from: 0.0, through: 30.0, by: 6.0).map { $0 }))
        XCTAssertLessThan(c.perSecond, 0.2)
        XCTAssertTrue(c.isSparse(windowSec: 30))
    }

    func testMedianGapIgnoresDuplicateTimestamps() {
        // Duplicate timestamps produce 0 gaps, which must not inflate the rate.
        let c = HRCadence.summarize(series([0, 0, 1, 2, 2, 3]))
        XCTAssertEqual(c.maxGapSec, 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(c.perSecond, 0)
    }
}
