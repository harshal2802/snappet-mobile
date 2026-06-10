import XCTest
@testable import Snappet

/// Unit tests for the **pure** `HistorySearch` query/chip filtering behind the History section's
/// `.searchable` + routine chips (issue #73) — no SwiftData container, no view.
final class HistorySearchTests: XCTestCase {

    private func session(_ name: String, daysAgo: Double) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        return WorkoutSession(routineName: name, startedAt: start,
                              completedAt: start.addingTimeInterval(3600))
    }

    func testQueryMatchesRoutineNameCaseInsensitively() {
        let sessions = [session("Push Day", daysAgo: 1), session("Leg Day", daysAgo: 2)]
        XCTAssertEqual(HistorySearch.apply(sessions, query: "push", routine: nil).map(\.routineName),
                       ["Push Day"])
        XCTAssertEqual(HistorySearch.apply(sessions, query: "DAY", routine: nil).count, 2)
    }

    func testBlankQueryPassesEverythingThrough() {
        let sessions = [session("Push Day", daysAgo: 1), session("Leg Day", daysAgo: 2)]
        XCTAssertEqual(HistorySearch.apply(sessions, query: "   ", routine: nil).count, 2)
    }

    func testRoutineChipFiltersExactlyAndComposesWithQuery() {
        let sessions = [session("Push Day", daysAgo: 1), session("Push Day", daysAgo: 8),
                        session("Leg Day", daysAgo: 2)]
        XCTAssertEqual(HistorySearch.apply(sessions, query: "", routine: "Push Day").count, 2)
        // The chip narrows first; a query that doesn't match within it finds nothing.
        XCTAssertTrue(HistorySearch.apply(sessions, query: "leg", routine: "Push Day").isEmpty)
    }

    func testNoMatchReturnsEmpty() {
        let sessions = [session("Push Day", daysAgo: 1)]
        XCTAssertTrue(HistorySearch.apply(sessions, query: "yoga", routine: nil).isEmpty)
    }

    func testRoutineNamesAreDistinctAndMostRecentFirst() {
        let sessions = [session("Leg Day", daysAgo: 5), session("Push Day", daysAgo: 1),
                        session("Leg Day", daysAgo: 2), session("Quick session", daysAgo: 9)]
        XCTAssertEqual(HistorySearch.routineNames(sessions),
                       ["Push Day", "Leg Day", "Quick session"])
    }

    func testEffectiveRoutineDropsAFilterNoLongerInHistory() {
        XCTAssertEqual(HistorySearch.effectiveRoutine(filter: "Push Day",
                                                      names: ["Push Day", "Leg Day"]), "Push Day")
        XCTAssertNil(HistorySearch.effectiveRoutine(filter: "Push Day", names: ["Leg Day"]),
                     "deleting the filtered routine's last session must not stick History on empty")
        XCTAssertNil(HistorySearch.effectiveRoutine(filter: nil, names: ["Leg Day"]))
    }
}
