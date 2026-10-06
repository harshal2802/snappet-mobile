import XCTest
import SwiftData
@testable import Snappet

/// Household P4 (prompt 159): power hour, ticks from the widget and the watch, the watch message, and the
/// snapshot the widget and the watch show.
@MainActor
final class HouseholdSurfacesTests: XCTestCase {
    private var container: ModelContainer!
    private let cal = HouseholdChoreBoardTests.cal
    private func day(_ n: Int, hour: Int = 9) -> Date { HouseholdChoreBoardTests.day(n, hour: hour) }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        HouseholdXP.shared.publish([])
        container = nil
    }

    // MARK: Power hour

    func testPowerHourCountsOnlyChoresDoneSinceItStarted() {
        let me = UUID(), sam = UUID(), dishes = UUID(), bins = UUID(), d = UUID()
        var seq = 0
        func op(_ k: ChoreOp.Kind, _ at: Date) -> ChoreOp { seq += 1; return ChoreOp(id: UUID(), device: d, seq: seq, at: at, kind: k) }
        let log = [
            op(.createChore(chore: dishes, fields: ChoreFields(name: "Dishes", repeats: .daily)), day(-1)),
            op(.createChore(chore: bins, fields: ChoreFields(name: "Bins", repeats: .weekly)), day(-1)),
            op(.complete(chore: dishes, member: me), day(0, hour: 9)),                     // before: not counted
            op(.startPowerHour(ends: day(0, hour: 11), target: 5), day(0, hour: 10)),
            op(.complete(chore: dishes, member: sam), day(0, hour: 10)),                   // same round as 9:00: not a new round
            op(.complete(chore: bins, member: sam), day(0, hour: 10).addingTimeInterval(60)),
        ]
        let board = ChoreBoard.fold(log)
        let hour = try! XCTUnwrap(board.powerHour(at: day(0, hour: 10).addingTimeInterval(300)))
        let progress = board.powerHourProgress(hour, now: day(0, hour: 10).addingTimeInterval(300))
        XCTAssertEqual(progress.done, 1, "only rounds first done inside the hour")
        XCTAssertEqual(progress.members, [sam])
        XCTAssertNil(board.powerHour(at: day(0, hour: 11)), "over at its end")
    }

    func testEndingAndRestartingPowerHours() {
        let d = UUID()
        let start = ChoreOp(id: UUID(), device: d, seq: 1, at: day(0), kind: .startPowerHour(ends: day(0, hour: 10), target: 3))
        let end = ChoreOp(id: UUID(), device: d, seq: 2, at: day(0).addingTimeInterval(600), kind: .endPowerHour)
        let again = ChoreOp(id: UUID(), device: d, seq: 3, at: day(0).addingTimeInterval(900),
                            kind: .startPowerHour(ends: day(0, hour: 10), target: 8))
        XCTAssertNil(ChoreBoard.fold([start, end]).powerHour(at: day(0).addingTimeInterval(700)))
        let board = ChoreBoard.fold([again, end, start])   // any order
        XCTAssertEqual(board.powerHour(at: day(0).addingTimeInterval(1000))?.target, 8)
        XCTAssertEqual(board.powerHours.count, 2)
    }

    func testPowerHourOpsRoundTripTheWire() throws {
        let op = ChoreOp(id: UUID(), device: UUID(), seq: 1, at: day(0),
                         kind: .startPowerHour(ends: day(0, hour: 10), target: 15))
        XCTAssertEqual(try ChoreOp.fromWire(op.wireData()).kind, op.kind)
        let json = String(decoding: try op.wireData(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""ends":"2026-10-05T10:00:00.000Z""#), json)
        XCTAssertTrue(json.contains(#""kind":"start_power_hour""#))
        let endOp = ChoreOp(id: UUID(), device: UUID(), seq: 2, at: day(0), kind: .endPowerHour)
        XCTAssertEqual(try ChoreOp.fromWire(endOp.wireData()).kind, .endPowerHour)
    }

    // MARK: Ticks away from the app

    func testWidgetAndWatchTicksApplyAtTheTapTimeAndAreIdempotent() throws {
        let store = HouseholdStore(context: container.mainContext)
        store.create(ChoreFields(name: "Dishes", repeats: .daily, assignment: .rotate([store.me])))
        let dishes = try XCTUnwrap(store.board.activeChores.first)
        let tapped = Date.now.addingTimeInterval(-120)

        let tick = ChoreToggle(choreID: dishes.id, desired: true, requestedAt: tapped)
        XCTAssertEqual(store.apply([tick]), [tick.id])
        XCTAssertEqual(store.board.completions.count, 1)
        XCTAssertEqual(store.board.completions.first?.at.timeIntervalSince1970 ?? 0, tapped.timeIntervalSince1970, accuracy: 0.01,
                       "stamped with when it was tapped, not when the app woke")

        store.apply([ChoreToggle(choreID: dishes.id, desired: true)])          // the watch sends it again
        XCTAssertEqual(store.board.completions.count, 1, "already done: nothing new")

        store.apply([ChoreToggle(choreID: dishes.id, desired: false)])
        XCTAssertTrue(store.board.completions.isEmpty, "untick retracts my tick")

        let unknown = ChoreToggle(choreID: UUID(), desired: true)
        XCTAssertEqual(store.apply([unknown]), [unknown.id], "an unknown chore is dropped from the outbox, not retried forever")
    }

    func testTicksApplyInTapOrder() throws {
        let store = HouseholdStore(context: container.mainContext)
        store.create(ChoreFields(name: "Bins", repeats: .weekly, assignment: .rotate([store.me])))
        let bins = try XCTUnwrap(store.board.activeChores.first)
        let on = ChoreToggle(choreID: bins.id, desired: true, requestedAt: .now.addingTimeInterval(-60))
        let off = ChoreToggle(choreID: bins.id, desired: false, requestedAt: .now.addingTimeInterval(-30))
        store.apply([off, on])   // delivered out of order
        XCTAssertTrue(store.board.completions.isEmpty, "tick then untick, by tap time")
    }

    func testWatchMessageRoundTrips() {
        let t = ChoreToggle(choreID: UUID(), desired: true, requestedAt: Date(timeIntervalSince1970: 1_791_190_800))
        XCTAssertEqual(HouseholdWatchMessage(payload: HouseholdWatchMessage.toggle(t).payload), .toggle(t))
        let data = Data("{}".utf8)
        XCTAssertEqual(HouseholdWatchMessage(payload: HouseholdWatchMessage.snapshot(data).payload), .snapshot(data))
        XCTAssertNil(HouseholdWatchMessage(payload: ["kind": "metrics"]), "workout messages aren't ours")
    }

    // MARK: Snapshot

    func testSnapshotListsMyChoresUndoneFirstWithGoalAndPowerHour() throws {
        let store = HouseholdStore(context: container.mainContext)
        store.create(ChoreFields(name: "Dishes", emoji: "🍽️", effort: .s, repeats: .daily, assignment: .rotate([store.me])))
        store.create(ChoreFields(name: "Hoover", emoji: "🧹", effort: .m, repeats: .weekly, assignment: .rotate([store.me])))
        store.create(ChoreFields(name: "Fridge", emoji: "🧊", effort: .l, repeats: .afterDone(days: 14), assignment: .upForGrabs))
        store.complete(try XCTUnwrap(store.board.activeChores.first { $0.name == "Dishes" }))
        store.setGoal(target: 5, reward: "Pizza")
        store.startPowerHour(minutes: 30, target: 4)

        let snap = HouseholdSurfaces.snapshot(store: store)
        XCTAssertEqual(snap.chores.map(\.name), ["Hoover", "Dishes"], "mine only (not up for grabs), undone first")
        XCTAssertEqual(snap.chores.map(\.done), [false, true])
        XCTAssertEqual(snap.remaining, 1)
        XCTAssertEqual(snap.goalTarget, 5)
        XCTAssertEqual(snap.goalDone, 1)
        XCTAssertEqual(snap.powerHour?.target, 4)
        XCTAssertEqual(snap.petName, "Biscuit")
        XCTAssertEqual(HouseholdWidgetStore.decode(try HouseholdWidgetStore.encode(snap)), snap)
    }
}
