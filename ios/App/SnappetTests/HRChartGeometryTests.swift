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
}
