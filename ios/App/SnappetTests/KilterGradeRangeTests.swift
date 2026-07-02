import XCTest
@testable import Snappet

/// Pure unit tests for the grade-range slider's geometry/snapping rules (`KilterGradeRange`) —
/// fraction↔index mapping and the crossed-thumb clamp. No UI, no device.
final class KilterGradeRangeTests: XCTestCase {

    // MARK: - fraction → index snapping

    func testIndexSnapsToNearestScaleEntry() {
        // 11 entries → 10 steps of 0.1 each.
        XCTAssertEqual(KilterGradeRange.index(forFraction: 0.0, count: 11), 0)
        XCTAssertEqual(KilterGradeRange.index(forFraction: 0.04, count: 11), 0)
        XCTAssertEqual(KilterGradeRange.index(forFraction: 0.06, count: 11), 1)
        XCTAssertEqual(KilterGradeRange.index(forFraction: 0.5, count: 11), 5)
        XCTAssertEqual(KilterGradeRange.index(forFraction: 1.0, count: 11), 10)
    }

    func testIndexClampsOutOfRangeFractions() {
        XCTAssertEqual(KilterGradeRange.index(forFraction: -0.4, count: 11), 0)
        XCTAssertEqual(KilterGradeRange.index(forFraction: 1.7, count: 11), 10)
    }

    func testIndexDegeneratesToZeroForTinyScales() {
        XCTAssertEqual(KilterGradeRange.index(forFraction: 0.9, count: 1), 0)
        XCTAssertEqual(KilterGradeRange.index(forFraction: 0.9, count: 0), 0)
    }

    // MARK: - index → fraction

    func testFractionIsInverseOfIndexOnTheGrid() {
        for i in 0...10 {
            let f = KilterGradeRange.fraction(forIndex: i, count: 11)
            XCTAssertEqual(KilterGradeRange.index(forFraction: f, count: 11), i)
        }
    }

    func testFractionClampsAndDegenerates() {
        XCTAssertEqual(KilterGradeRange.fraction(forIndex: -3, count: 11), 0)
        XCTAssertEqual(KilterGradeRange.fraction(forIndex: 99, count: 11), 1)
        XCTAssertEqual(KilterGradeRange.fraction(forIndex: 5, count: 1), 0)
    }

    // MARK: - crossed-thumb clamp

    func testClampKeepsAValidPairUntouched() {
        let pair = KilterGradeRange.clamp(lo: 2, hi: 7, dragging: .lo)
        XCTAssertEqual(pair.lo, 2)
        XCTAssertEqual(pair.hi, 7)
    }

    func testDraggedLowThumbPushesTheHighOneAlong() {
        let pair = KilterGradeRange.clamp(lo: 8, hi: 5, dragging: .lo)
        XCTAssertEqual(pair.lo, 8)
        XCTAssertEqual(pair.hi, 8)
    }

    func testDraggedHighThumbPushesTheLowOneAlong() {
        let pair = KilterGradeRange.clamp(lo: 5, hi: 2, dragging: .hi)
        XCTAssertEqual(pair.lo, 2)
        XCTAssertEqual(pair.hi, 2)
    }

    func testEqualThumbsAreValid() {
        let pair = KilterGradeRange.clamp(lo: 4, hi: 4, dragging: .hi)
        XCTAssertEqual(pair.lo, 4)
        XCTAssertEqual(pair.hi, 4)
    }
}
