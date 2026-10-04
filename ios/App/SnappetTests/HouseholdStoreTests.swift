import XCTest
import SwiftData
@testable import Snappet

/// Household P1 (prompt 156): the SwiftData edge persists ops and rebuilds the board by replaying them,
/// and chore XP reaches the progression ledger under the shared daily cap.
@MainActor
final class HouseholdStoreTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        HouseholdXP.shared.publish(board: ChoreBoard(), me: UUID())   // don't leak chore XP into other tests
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    func testFirstOpenCreatesOneHouseholdWithYouAsTheFirstMember() throws {
        let store = HouseholdStore(context: context)
        XCTAssertEqual(store.board.members, [HouseholdMember(id: store.me, name: "You")])
        _ = HouseholdStore(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Household>()), 1, "reopening reuses it")
    }

    func testTheBoardSurvivesAReopenByReplayingTheLog() throws {
        let store = HouseholdStore(context: context)
        store.create(ChoreFields(name: "Dishes", effort: .s, repeats: .daily, assignment: .rotate([store.me])))
        let chore = try XCTUnwrap(store.board.activeChores.first)
        store.complete(chore)
        store.setGoal(target: 5, reward: "Pizza")

        let reopened = HouseholdStore(context: context)
        XCTAssertEqual(reopened.board, store.board)
        XCTAssertEqual(reopened.board.completions.count, 1)
        XCTAssertEqual(reopened.board.goal(now: .now)?.target, 5)
        XCTAssertEqual(reopened.ops.map(\.seq).sorted(), [1, 2, 3, 4], "one device, counting up")
    }

    func testAnEditWritesOnlyTheFieldsThatChanged() throws {
        let store = HouseholdStore(context: context)
        store.create(ChoreFields(name: "Fridge", emoji: "🧊", room: "Kitchen", effort: .l,
                                 repeats: .afterDone(days: 14), assignment: .upForGrabs))
        let chore = try XCTUnwrap(store.board.activeChores.first)
        store.edit(chore, to: ChoreFields(name: "Fridge", emoji: "🧊", room: "Kitchen", effort: .m,
                                          repeats: .afterDone(days: 14), assignment: .upForGrabs))
        let last = try XCTUnwrap(store.ops.max { ChoreOp.precedes($0, $1) })
        XCTAssertEqual(last.kind, .editChore(chore: chore.id, fields: ChoreFields(effort: .m)))
        let count = store.ops.count
        store.edit(try XCTUnwrap(store.board.activeChores.first),
                   to: ChoreFields(name: "Fridge", emoji: "🧊", room: "Kitchen", effort: .m,
                                   repeats: .afterDone(days: 14), assignment: .upForGrabs))
        XCTAssertEqual(store.ops.count, count, "no change, no op")
    }

    func testUntickRetractsMyTickAndItsXP() throws {
        let store = HouseholdStore(context: context)
        store.create(ChoreFields(name: "Hoover", effort: .m, repeats: .weekly, assignment: .rotate([store.me])))
        let chore = try XCTUnwrap(store.board.activeChores.first)
        store.complete(chore)
        XCTAssertEqual(HouseholdXP.shared.earnings.map { $0.items.map(\.xp) }, [[Progression.Rules.choreM]])
        XCTAssertEqual(HouseholdXP.shared.earnings.first?.items.first?.label, "🧹 Hoover")
        store.uncomplete(chore)
        XCTAssertTrue(store.board.completions.isEmpty)
        XCTAssertTrue(HouseholdXP.shared.earnings.isEmpty)
    }

    func testLaunchLoadReadsTheStoredLogWithoutCreatingAHousehold() throws {
        HouseholdXP.shared.load(context: context)
        XCTAssertTrue(HouseholdXP.shared.earnings.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Household>()), 0, "loading never creates one")

        let store = HouseholdStore(context: context)
        store.create(ChoreFields(name: "Bins", effort: .s, repeats: .weekly, assignment: .rotate([store.me])))
        store.complete(try XCTUnwrap(store.board.activeChores.first))
        HouseholdXP.shared.publish(board: ChoreBoard(), me: UUID())
        HouseholdXP.shared.load(context: context)
        XCTAssertEqual(HouseholdXP.shared.earnings.count, 1)
    }

    // MARK: - Chore XP in the ledger

    private func earning(_ xp: Int, at: Date) -> Progression.Earning {
        Progression.Earning(id: UUID(), at: at, items: [.init(label: "🧹 Chore", xp: xp)])
    }

    func testChoreXPAddsToTheLedgerButNotToTheSessionCount() {
        let day = Date(timeIntervalSince1970: 1_791_190_800)
        let ledger = Progression.ledger([], schedules: [:], extras: [earning(35, at: day), earning(10, at: day)])
        XCTAssertEqual(ledger.totalXP, 45)
        XCTAssertEqual(ledger.sessionCount, 0, "chores don't flip Home to training-first")
    }

    func testChoresShareTheDailyCapFirstComeFirstServed() {
        let day = Date(timeIntervalSince1970: 1_791_190_800)
        let chores = (0..<10).map { earning(35, at: day.addingTimeInterval(Double($0) * 60)) }   // 350 raw
        let ledger = Progression.ledger([], schedules: [:], extras: chores)
        XCTAssertEqual(ledger.totalXP, Progression.Rules.dailyCap)
        XCTAssertEqual(ledger.awards[chores[9].id]?.total, 0)
        XCTAssertEqual(ledger.awards[chores[8].id]?.capped, true)
        let nextDay = Progression.ledger([], schedules: [:], extras: chores + [earning(20, at: day.addingTimeInterval(86_400))])
        XCTAssertEqual(nextDay.totalXP, Progression.Rules.dailyCap + 20, "a new day, a new cap")
    }

    func testOnlyMyCreditsEarnXPByEffort() {
        let me = UUID(), sam = UUID(), d = UUID(), c = UUID()
        let at = Date(timeIntervalSince1970: 1_791_190_800)
        let board = ChoreBoard.fold([
            ChoreOp(id: UUID(), device: d, seq: 1, at: at,
                    kind: .createChore(chore: c, fields: ChoreFields(name: "Fridge", emoji: "🧊", effort: .l,
                                                                    repeats: .afterDone(days: 14)))),
            ChoreOp(id: UUID(), device: d, seq: 2, at: at.addingTimeInterval(60), kind: .complete(chore: c, member: sam)),
            ChoreOp(id: UUID(), device: d, seq: 3, at: at.addingTimeInterval(120), kind: .complete(chore: c, member: me)),
        ])
        let mine = HouseholdXP.earnings(board: board, me: me)
        XCTAssertEqual(mine.map { $0.items }, [[.init(label: "🧊 Fridge", xp: Progression.Rules.choreL)]],
                       "credited even though Sam did it first: both did the round")
    }
}
