import XCTest
@testable import Snappet

/// Prompt 139 — exact weights: typed values are kept exactly, ± moves from wherever you are by the
/// chosen step, and the defaults match the old fixed 2.5 kg behaviour.
final class WeightEntryTests: XCTestCase {

    func testDefaultsMatchTheOldBehaviour() {
        XCTAssertEqual(WeightEntry.step(stored: 0, unit: .kg), 2.5)
        XCTAssertEqual(WeightEntry.step(stored: 0, unit: .lb), 5)
    }

    func testStoredStepMustBeOfferedForTheUnit() {
        XCTAssertEqual(WeightEntry.step(stored: 1.25, unit: .kg), 1.25)
        XCTAssertEqual(WeightEntry.step(stored: 1.25, unit: .lb), 5, "1.25 isn't an lb choice → default")
        XCTAssertEqual(WeightEntry.step(stored: 10, unit: .lb), 10)
    }

    func testNudgeMovesFromAnArbitraryValueWithoutSnapping() {
        XCTAssertEqual(WeightEntry.nudge(71.3, by: 2.5), 73.8)
        XCTAssertEqual(WeightEntry.nudge(71.3, by: -1.25), 70.05)
        XCTAssertEqual(WeightEntry.nudge(1, by: -2.5), 0, "never below bodyweight")
        XCTAssertEqual(WeightEntry.nudge(1999, by: 5), 2000)
    }

    func testNudgeDoesNotAccumulateFloatNoise() {
        var w = 0.0
        for _ in 0..<10 { w = WeightEntry.nudge(w, by: 0.1) }
        XCTAssertEqual(w, 1.0)
        XCTAssertEqual(SetMeasure.formatWeight(w), "1")
    }

    func testParseAcceptsDotOrCommaAndRejectsJunk() {
        XCTAssertEqual(WeightEntry.parse("71.3"), 71.3)
        XCTAssertEqual(WeightEntry.parse("71,3"), 71.3)
        XCTAssertEqual(WeightEntry.parse(" 80 "), 80)
        XCTAssertEqual(WeightEntry.parse(""), 0, "empty = bodyweight")
        XCTAssertNil(WeightEntry.parse("1.2.3"))
        XCTAssertNil(WeightEntry.parse("-5"))
        XCTAssertNil(WeightEntry.parse("abc"))
        XCTAssertNil(WeightEntry.parse("2500"))
    }

    func testEditTextRoundTrips() {
        XCTAssertEqual(WeightEntry.editText(0), "")
        XCTAssertEqual(WeightEntry.editText(71.3), "71.3")
        XCTAssertEqual(WeightEntry.editText(80), "80")
        XCTAssertEqual(WeightEntry.parse(WeightEntry.editText(71.3)), 71.3)
    }
}
