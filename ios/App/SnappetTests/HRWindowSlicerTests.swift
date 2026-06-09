import XCTest
@testable import Snappet

/// Unit tests for the pure `HRWindowSlicer` — the single guarantee that a tagged video never silently
/// loses its HR overlay. No device/Photos: pure value math. Each case maps to a confirmed failure mode
/// from the HR-missing deep review.
final class HRWindowSlicerTests: XCTestCase {

    // MARK: In-coverage

    func testInWindowSamplesSlicedAndRebasedToZero() {
        let series = [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 110),
                      HRPoint(t: 20, bpm: 120), HRPoint(t: 30, bpm: 130)]
        let out = HRWindowSlicer.slice(series, start: 10, span: 10)   // window [10, 20]
        // Endpoints interpolated at 10 and 20 → bpm 110 and 120, rebased to t=0 and t=10.
        XCTAssertEqual(out.first!.t, 0, accuracy: 1e-6)
        XCTAssertEqual(out.first!.bpm, 110, accuracy: 1e-6)
        XCTAssertEqual(out.last!.t, 10, accuracy: 1e-6)
        XCTAssertEqual(out.last!.bpm, 120, accuracy: 1e-6)
    }

    /// Sparse series + short clip whose window lands BETWEEN two samples → still drawable + interpolated
    /// (the strict-filter bug returned []). [sparse-ble-cadence-short-clip / no-bracket-clamp]
    func testSparseGapStillInterpolatesNonEmpty() {
        let series = [HRPoint(t: 10, bpm: 100), HRPoint(t: 20, bpm: 120)]
        let out = HRWindowSlicer.slice(series, start: 12, span: 2)    // window [12, 14], no sample inside
        XCTAssertGreaterThanOrEqual(out.count, 2)
        // value at t=12 = 104, at t=14 = 108 (linear between 100@10 and 120@20).
        XCTAssertEqual(out.first!.bpm, 104, accuracy: 1e-6)
        XCTAssertEqual(out.last!.bpm, 108, accuracy: 1e-6)
    }

    func testRRIntervalsPreservedThroughSlice() {
        let series = [HRPoint(t: 0, bpm: 100, rrIntervalsMs: [800, 810]),
                      HRPoint(t: 10, bpm: 110, rrIntervalsMs: [790, 805])]
        let out = HRWindowSlicer.slice(series, start: 0, span: 10)
        XCTAssertTrue(out.contains { ($0.rrIntervalsMs?.isEmpty == false) })
    }

    // MARK: Edge clamp (within tolerance)

    /// Band connected late: clip filmed before the first sample, within tolerance → flat last-known.
    /// [clip-window-before-first-sample / ble-late-connection]
    func testWindowBeforeFirstSampleClampsToFirstWithinTolerance() {
        let series = [HRPoint(t: 120, bpm: 72), HRPoint(t: 180, bpm: 80)]
        let out = HRWindowSlicer.slice(series, start: 40, span: 15)   // [40,55], gap to 120 = 65 ≤ 90
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.bpm == 72 })
        XCTAssertEqual(out.first!.t, 0, accuracy: 1e-6)
        XCTAssertEqual(out.last!.t, 15, accuracy: 1e-6)
    }

    /// Victory clip in the trailing pad after HR stopped, within tolerance → flat last-known.
    /// [clip-in-trailing-pad-past-last-sample / offset-no-upper-bound-clamp]
    func testWindowAfterLastSampleClampsToLastWithinTolerance() {
        let series = [HRPoint(t: 1000, bpm: 150), HRPoint(t: 1200, bpm: 95)]
        let out = HRWindowSlicer.slice(series, start: 1250, span: 15)  // gap 50 ≤ 90
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.bpm == 95 })
    }

    // MARK: Honest-empty (beyond tolerance)

    /// Cross-day manual pick, or a cool-down clip filmed minutes after HR stopped → honest empty
    /// (we don't pass off a reading 90 s+ away as live). [manual-picker-no-window-filter]
    func testFarBeforeCoverageReturnsEmpty() {
        let series = [HRPoint(t: 1000, bpm: 120), HRPoint(t: 2000, bpm: 130)]
        XCTAssertTrue(HRWindowSlicer.slice(series, start: 0, span: 30).isEmpty)        // gap 970 > 90
    }
    func testFarAfterCoverageReturnsEmpty() {
        let series = [HRPoint(t: 0, bpm: 120), HRPoint(t: 3600, bpm: 130)]
        XCTAssertTrue(HRWindowSlicer.slice(series, start: 86_400, span: 30).isEmpty)   // next-day pick
    }
    func testEmptySeriesReturnsEmpty() {
        XCTAssertTrue(HRWindowSlicer.slice([], start: 0, span: 10).isEmpty)
    }

    // MARK: ≥2-point guarantee

    /// One-sample session → duplicated to two points so the chart's ≥2 gate passes (a flat line).
    /// [chart-playhead-dot-vanishes]
    func testSingleSampleSessionYieldsTwoFlatPoints() {
        let out = HRWindowSlicer.slice([HRPoint(t: 5, bpm: 130)], start: 0, span: 20)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.bpm == 130 })
        XCTAssertEqual(out.last!.t, 20, accuracy: 1e-6)
    }

    func testSpanZeroGuardedStillDrawable() {
        let out = HRWindowSlicer.slice([HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 120)],
                                       start: 5, span: 0)
        XCTAssertGreaterThanOrEqual(out.count, 2)
    }

    /// Anything the slicer returns must be chart-drawable (`normalizedPoints` non-empty) — the round
    /// trip that guarantees "non-empty slice ⇒ visible overlay".
    func testNonEmptySliceIsAlwaysChartDrawable() {
        let series = [HRPoint(t: 10, bpm: 100), HRPoint(t: 20, bpm: 120)]
        for (start, span) in [(12.0, 2.0), (0.0, 15.0), (25.0, 10.0), (5.0, 4.0)] {
            let out = HRWindowSlicer.slice(series, start: start, span: span)
            if !out.isEmpty {
                XCTAssertFalse(HRChartGeometry.normalizedPoints(out).isEmpty,
                               "slice(start:\(start), span:\(span)) must be drawable")
            }
        }
    }
}
