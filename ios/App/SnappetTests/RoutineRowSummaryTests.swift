import XCTest
@testable import Snappet

/// Prompt 219: a routine row's counts read in words ("1 exercise · 1 set", not "1 exercises · 1 sets").
final class RoutineRowSummaryTests: XCTestCase {
    func testSingularAndPlural() {
        XCTAssertEqual(RoutineRow.summary(exercises: 1, sets: 1, level: nil), "1 exercise · 1 set")
        XCTAssertEqual(RoutineRow.summary(exercises: 3, sets: 10, level: nil), "3 exercises · 10 sets")
        XCTAssertEqual(RoutineRow.summary(exercises: 5, sets: 18, level: "Intermediate"), "5 exercises · 18 sets · Intermediate")
    }
}
