import XCTest
@testable import Snappet

/// Prompt 218: Explore's header reads in words ("859 strength exercises", not "859 strengths").
final class LibraryExploreCountTests: XCTestCase {
    func testCountsReadNaturally() {
        XCTAssertEqual(WorkoutLibraryView.exploreCount(859, .strength), "859 strength exercises")
        XCTAssertEqual(WorkoutLibraryView.exploreCount(1, .strength), "1 strength exercise")
        XCTAssertEqual(WorkoutLibraryView.exploreCount(24, .climb), "24 climbs")
        XCTAssertEqual(WorkoutLibraryView.exploreCount(3, .other), "3 activities")
        XCTAssertEqual(WorkoutLibraryView.exploreCount(12, nil), "12 items")
        XCTAssertEqual(WorkoutLibraryView.exploreCount(2, .dance), "2 dances")
    }
}
