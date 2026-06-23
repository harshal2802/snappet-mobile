import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for the pure HR-chart geometry (no device/SwiftUI): normalized line points, the
/// time→bpm sampling the playhead dot uses, and the padded y-range.
final class HRChartGeometryTests: XCTestCase {

    func testNormalizedPointsMapTimeAcross0to1AndOrderByBPM() {
        let s = [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 200)]
        let pts = HRChartGeometry.normalizedPoints(s)
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts.first!.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pts.last!.x, 1, accuracy: 1e-9)
        XCTAssertLessThan(pts.first!.y, pts.last!.y)   // higher bpm → higher normalized y
    }

    func testNormalizedPointsEmptyForFewerThanTwo() {
        XCTAssertTrue(HRChartGeometry.normalizedPoints([HRPoint(t: 0, bpm: 120)]).isEmpty)
        XCTAssertTrue(HRChartGeometry.normalizedPoints([]).isEmpty)
    }

    func testSampleBPMInterpolatesAndClamps() {
        let s = [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 200)]
        XCTAssertEqual(HRChartGeometry.sampleBPM(s, atFraction: 0.5)!, 150, accuracy: 1e-6)   // t=5
        XCTAssertEqual(HRChartGeometry.sampleBPM(s, atFraction: 0)!, 100, accuracy: 1e-6)
        XCTAssertEqual(HRChartGeometry.sampleBPM(s, atFraction: 1)!, 200, accuracy: 1e-6)
        XCTAssertEqual(HRChartGeometry.sampleBPM(s, atFraction: 5)!, 200, accuracy: 1e-6)     // clamp >1
        XCTAssertNil(HRChartGeometry.sampleBPM([], atFraction: 0.5))
    }

    func testBpmRangePadsAndHandlesFlatData() {
        let (lo, hi) = HRChartGeometry.bpmRange([HRPoint(t: 0, bpm: 100), HRPoint(t: 1, bpm: 200)])
        XCTAssertLessThan(lo, 100); XCTAssertGreaterThan(hi, 200)
        let flat = HRChartGeometry.bpmRange([HRPoint(t: 0, bpm: 120)])
        XCTAssertLessThan(flat.min, 120); XCTAssertGreaterThan(flat.max, 120)
    }

    // MARK: - displaySeries (prompt 101 — smooth resample for the chart + gliding dot)

    func testDisplaySeriesPreservesEndpointsAndDensifies() {
        // A 30s window with a few interior points → a dense grid spanning the SAME [0, maxT].
        let raw = [HRPoint(t: 0, bpm: 120), HRPoint(t: 10, bpm: 150),
                   HRPoint(t: 20, bpm: 140), HRPoint(t: 30, bpm: 160)]
        let dense = HRChartGeometry.displaySeries(raw)
        XCTAssertGreaterThan(dense.count, raw.count)            // densified
        XCTAssertEqual(dense.first!.t, 0, accuracy: 1e-9)       // endpoints preserved
        XCTAssertEqual(dense.last!.t, 30, accuracy: 1e-6)       // so fraction alignment (÷ maxT) holds
        for p in dense { XCTAssertTrue(p.t >= 0 && p.t <= 30 + 1e-6) }
    }

    func testDisplaySeriesKeepsTwoPointWindowCollinear() {
        // The reported symptom: a 2-point window must NOT gain a fabricated wiggle — resampling a
        // straight line yields collinear points (still a straight line; honest).
        let raw = [HRPoint(t: 0, bpm: 135), HRPoint(t: 30, bpm: 139)]
        let dense = HRChartGeometry.displaySeries(raw)
        XCTAssertGreaterThanOrEqual(dense.count, 2)
        // Every resampled bpm lies on the 135→139 line within smoothing tolerance.
        for p in dense {
            let expected = 135 + (139 - 135) * (p.t / 30)
            XCTAssertEqual(p.bpm, expected, accuracy: 0.5)
        }
    }

    func testDisplaySeriesIsBoundedForLongWindows() {
        // A 30-min editor/session window must not balloon the path — capped by maxPoints.
        let raw = (0...1800).map { HRPoint(t: Double($0), bpm: 100 + Double($0 % 40)) }
        let dense = HRChartGeometry.displaySeries(raw, maxPoints: 240)
        XCTAssertLessThanOrEqual(dense.count, 242)
        XCTAssertEqual(dense.last!.t, 1800, accuracy: 1.0)
    }

    func testDisplaySeriesPassesThroughDegenerateInput() {
        XCTAssertEqual(HRChartGeometry.displaySeries([]).count, 0)
        XCTAssertEqual(HRChartGeometry.displaySeries([HRPoint(t: 5, bpm: 120)]).count, 1)
        // All-same-timestamp (maxT == 0) → returned unchanged, never a divide-by-zero.
        XCTAssertEqual(HRChartGeometry.displaySeries([HRPoint(t: 0, bpm: 120), HRPoint(t: 0, bpm: 130)]).count, 2)
    }
}
