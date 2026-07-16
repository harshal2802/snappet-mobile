import XCTest
@testable import Snappet

/// Unit tests for the Siri/Shortcuts plumbing's PURE pieces (#81 Phase 3): the `PendingAppAction`
/// codec the App-Group inbox round-trips, and the `HabitEntity` mapping from a snapshot habit. The
/// App-Group directory I/O (`AppActionInbox` enqueue/drain) and the live `HabitEntityQuery` reads are
/// the thin device edge and aren't unit-tested; the serialisable contract + mapping are.
final class AppActionInboxTests: XCTestCase {

    private func roundTrip(_ action: PendingAppAction) throws -> PendingAppAction {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(PendingAppAction.self, from: data)
    }

    func testPendingAppActionRoundTripsEveryCase() throws {
        let cases: [PendingAppAction] = [
            .startPomodoro,
            .startRoutine,
            .openModule("pomodoro"),
            .openModule("workout-log"),
            .quickJournal(nil),
            .quickJournal("Felt great after the climb"),
        ]
        for action in cases {
            XCTAssertEqual(try roundTrip(action), action, "round-trip changed \(action)")
        }
    }

    func testOpenModuleCarriesItsID() throws {
        guard case .openModule(let id) = try roundTrip(.openModule("kilter")) else {
            return XCTFail("expected .openModule")
        }
        XCTAssertEqual(id, "kilter")
    }

    func testQuickJournalPreservesNilVsText() throws {
        XCTAssertEqual(try roundTrip(.quickJournal(nil)), .quickJournal(nil))
        XCTAssertEqual(try roundTrip(.quickJournal("hi")), .quickJournal("hi"))
        XCTAssertNotEqual(try roundTrip(.quickJournal(nil)), .quickJournal(""))   // nil ≠ empty
    }

    // MARK: - ModuleChoice ↔ module id

    func testModuleChoiceMapsToRegistryIDs() {
        XCTAssertEqual(ModuleChoice.gymTracker.moduleID, "workout-log")   // #74 persisted id
        XCTAssertEqual(ModuleChoice.habits.moduleID, "habit")
        XCTAssertEqual(ModuleChoice.splitExpenses.moduleID, "expense")
        // Every choice maps to a non-empty id, and a case display representation exists.
        for choice in ModuleChoice.allCases {
            XCTAssertFalse(choice.moduleID.isEmpty)
            XCTAssertNotNil(ModuleChoice.caseDisplayRepresentations[choice])
        }
    }

    // MARK: - Inbox → navigation routing (the in-app dispatch decision)

    func testRouteStartPomodoroOpensPomodoroAndStartsTimer() {
        let r = AppActionRouter.route(for: .startPomodoro)
        XCTAssertEqual(r, AppActionRouter.Route(moduleID: "pomodoro", startPomodoro: true))
    }

    func testRouteOpenModulePassesTheID() {
        XCTAssertEqual(AppActionRouter.route(for: .openModule("kilter")),
                       AppActionRouter.Route(moduleID: "kilter"))
    }

    func testRouteStartRoutineOpensGymTracker() {
        // Guards the literal that the review flagged: startRoutine → the #74 persisted id.
        XCTAssertEqual(AppActionRouter.route(for: .startRoutine),
                       AppActionRouter.Route(moduleID: "workout-log"))
    }

    func testRouteQuickJournalOpensJournalWithCompose() {
        XCTAssertEqual(AppActionRouter.route(for: .quickJournal("note")),
                       AppActionRouter.Route(moduleID: "journal",
                                             journalCompose: JournalComposeRequest(text: "note")))
        XCTAssertEqual(AppActionRouter.route(for: .quickJournal(nil)),
                       AppActionRouter.Route(moduleID: "journal",
                                             journalCompose: JournalComposeRequest(text: nil)))
    }

    /// Every open-module target resolves to a registered module id (mirrors the dispatch path).
    func testRouteModuleIDsAreRegistered() {
        let registered = Set(["pomodoro", "habit", "journal", "workout-log", "workout",
                              "kilter", "budget", "expense", "tip"])
        for choice in ModuleChoice.allCases {
            XCTAssertTrue(registered.contains(AppActionRouter.route(for: .openModule(choice.moduleID)).moduleID))
        }
        XCTAssertTrue(registered.contains(AppActionRouter.route(for: .startRoutine).moduleID))
        XCTAssertTrue(registered.contains(AppActionRouter.route(for: .startPomodoro).moduleID))
    }

    // MARK: - HabitEntity mapping

    func testHabitEntityMapsFromSnapshotItem() {
        let id = UUID()
        let item = SnappetWidgetSnapshot.HabitItem(id: id, name: "Read", symbol: "book", doneToday: false)
        let entity = HabitEntity(item)
        XCTAssertEqual(entity.id, id)
        XCTAssertEqual(entity.name, "Read")
    }
}
