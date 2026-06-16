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

    /// A session whose exercises track the given `SetKind`s (one exercise per kind), for the
    /// tracking-type facet tests (workout-with-timer PR 6). `kindRaw` is what `SessionExercise.kind`
    /// reads; `nil`-kind legacy data would resolve to `.repsWeight` (covered by passing `.repsWeight`).
    private func session(_ name: String, daysAgo: Double, kinds: [SetKind]) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        let exercises = kinds.map {
            SessionExercise(exerciseId: "adhoc-\($0.rawValue)", targetSets: 0, targetReps: "",
                            targetRestSeconds: 0, sets: [], kindRaw: $0.rawValue)
        }
        return WorkoutSession(routineName: name, startedAt: start,
                              completedAt: start.addingTimeInterval(3600), exercises: exercises)
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

    // MARK: - Tracking-type facet (workout-with-timer PR 6)

    func testEmptyKindsPassesEveryTrackingTypeThrough() {
        let sessions = [session("Lift", daysAgo: 1, kinds: [.repsWeight]),
                        session("Hold", daysAgo: 2, kinds: [.duration]),
                        session("Boulder", daysAgo: 3, kinds: [.climbAttempt])]
        XCTAssertEqual(HistorySearch.apply(sessions, query: "", routine: nil, kinds: []).count, 3)
        // Default arg (no kinds) is also a pass-through, so the existing call sites are unaffected.
        XCTAssertEqual(HistorySearch.apply(sessions, query: "", routine: nil).count, 3)
    }

    func testSingleKindKeepsOnlySessionsContainingIt() {
        let sessions = [session("Lift", daysAgo: 1, kinds: [.repsWeight]),
                        session("Hold", daysAgo: 2, kinds: [.duration]),
                        session("Mixed", daysAgo: 3, kinds: [.repsWeight, .duration])]
        // Only sessions with a Timed exercise survive — the pure-strength "Lift" drops out.
        XCTAssertEqual(HistorySearch.apply(sessions, query: "", routine: nil, kinds: [.duration])
            .map(\.routineName).sorted(), ["Hold", "Mixed"])
    }

    func testMultipleKindsAreAUnion() {
        let sessions = [session("Lift", daysAgo: 1, kinds: [.repsWeight]),
                        session("Hold", daysAgo: 2, kinds: [.duration]),
                        session("Boulder", daysAgo: 3, kinds: [.climbAttempt])]
        // Selecting two kinds keeps a session tracking EITHER (union), not the intersection.
        let kept = HistorySearch.apply(sessions, query: "", routine: nil,
                                       kinds: [.duration, .climbAttempt]).map(\.routineName).sorted()
        XCTAssertEqual(kept, ["Boulder", "Hold"])
    }

    func testTrackingTypeComposesWithRoutineAndQuery() {
        let sessions = [session("Push Day", daysAgo: 1, kinds: [.repsWeight]),
                        session("Push Day", daysAgo: 2, kinds: [.duration]),
                        session("Leg Day", daysAgo: 3, kinds: [.duration])]
        // Routine narrows to "Push Day" first, then the Timed facet keeps only the timed Push Day.
        XCTAssertEqual(HistorySearch.apply(sessions, query: "", routine: "Push Day",
                                           kinds: [.duration]).count, 1)
        // The query layers on top: a non-matching query within the faceted set finds nothing.
        XCTAssertTrue(HistorySearch.apply(sessions, query: "leg", routine: "Push Day",
                                          kinds: [.duration]).isEmpty)
        // The composable helper on its own keeps any-of-kind across the whole list.
        XCTAssertEqual(HistorySearch.filterByTrackingTypes(sessions, kinds: [.repsWeight]).count, 1)
    }
}
