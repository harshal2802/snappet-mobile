import XCTest
@testable import Snappet

/// One set's weight reads as entered — the "edited weight seems to round" bug (prompt 192).
final class SetWeightLabelTests: XCTestCase {
    func testExactInTheUnitItWasEnteredIn() {
        XCTAssertEqual(WorkoutMath.setWeight(67.5, enteredIn: .kg, unit: .kg), "67.5 kg")
        XCTAssertEqual(WorkoutMath.setWeight(71.25, enteredIn: .kg, unit: .kg), "71.25 kg")
        XCTAssertEqual(WorkoutMath.setWeight(60, enteredIn: .kg, unit: .kg), "60 kg")
        XCTAssertEqual(WorkoutMath.setWeight(135, enteredIn: .lb, unit: .lb), "135 lb")
        XCTAssertEqual(WorkoutMath.setWeight(67.5, enteredIn: nil, unit: .kg), "67.5 kg", "unknown unit = kg")
    }

    func testWholeAfterAConversion() {
        XCTAssertEqual(WorkoutMath.setWeight(100, enteredIn: .kg, unit: .lb), "220 lb")
    }

    func testBestsHeldInKg() {
        XCTAssertEqual(WorkoutMath.setWeight(kg: 67.5, unit: .kg), "67.5 kg")
        XCTAssertEqual(ActivityDashboard.weightLabel(kg: 67.5, unit: .kg), "67.5 kg")
    }

    func testTypedTextParsesLikeTheField() {
        XCTAssertEqual(WeightEntry.parse("67.5"), 67.5)
        XCTAssertEqual(WeightEntry.parse("67,5"), 67.5, "a comma decimal")
        XCTAssertEqual(WeightEntry.parse("67."), 67, "mid-typing")
        XCTAssertNil(WeightEntry.parse("6.7.5"))
    }
}
