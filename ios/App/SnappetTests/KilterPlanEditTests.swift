import XCTest
@testable import Snappet

/// Prompt 209 — edit a planned session: remove, add, reorder, move between sections; during a session only pending
/// picks can go, and an added climb is filed by grade.
final class KilterPlanEditTests: XCTestCase {
    private func item(_ uuid: String, _ goal: KilterRecommender.Goal, order: Int, diff: Double = 20,
                      status: KilterPlanItemStatus = .pending) -> KilterPlanItem {
        KilterPlanItem(order: order, goal: goal, climbUUID: uuid, climbName: uuid, setter: "s", gradeLabel: "g",
                       difficulty: diff, status: status)
    }
    private func climb(_ uuid: String, _ diff: Double = 20) -> KilterListItem {
        KilterListItem(uuid: uuid, name: uuid, setter: "s", difficulty: diff, gradeLabel: "g", quality: 2, ascents: 1)
    }
    private func order(_ items: [KilterPlanItem]) -> [String] { items.sorted { $0.order < $1.order }.map(\.climbUUID) }

    private lazy var plan = [item("w1", .warmup, order: 0), item("w2", .warmup, order: 1),
                             item("s1", .send, order: 2), item("s2", .send, order: 3), item("p1", .project, order: 4)]

    func testRemoveRenumbers() {
        let out = KilterPlanProgress.removing(id: plan[2].id, from: plan, inSession: false)
        XCTAssertEqual(order(out), ["w1", "w2", "s2", "p1"])
        XCTAssertEqual(out.map(\.order).sorted(), [0, 1, 2, 3])
    }

    func testAddLandsAtTheEndOfItsSectionAndNeverTwice() {
        let out = KilterPlanProgress.adding(climb("w3"), as: .warmup, to: plan)
        XCTAssertEqual(order(out), ["w1", "w2", "w3", "s1", "s2", "p1"])
        XCTAssertEqual(KilterPlanProgress.adding(climb("s1"), as: .send, to: plan), plan, "already in the plan")
        let toEmpty = KilterPlanProgress.adding(climb("p2"), as: .project, to: Array(plan.prefix(4)))
        XCTAssertEqual(order(toEmpty).last, "p2")
    }

    func testMoveBetweenSectionsAndReorderWithin() {
        let moved = KilterPlanProgress.moving(id: plan[0].id, to: .project, in: plan)
        XCTAssertEqual(order(moved), ["w2", "s1", "s2", "p1", "w1"])
        XCTAssertEqual(moved.first { $0.climbUUID == "w1" }?.goal, .project)

        let swapped = KilterPlanProgress.reordering(.send, from: IndexSet(integer: 1), to: 0, in: plan)
        XCTAssertEqual(order(swapped), ["w1", "w2", "s2", "s1", "p1"])
    }

    func testDuringASessionOnlyPendingPicksCanBeRemoved() {
        var live = plan
        live[0].statusRaw = KilterPlanItemStatus.sent.rawValue
        live[1].statusRaw = KilterPlanItemStatus.attempted.rawValue
        XCTAssertEqual(KilterPlanProgress.removing(id: live[0].id, from: live, inSession: true), live, "sent stays")
        XCTAssertEqual(KilterPlanProgress.removing(id: live[1].id, from: live, inSession: true), live, "tried stays")
        XCTAssertEqual(KilterPlanProgress.removing(id: live[2].id, from: live, inSession: true).count, 4)
        XCTAssertTrue(KilterPlanProgress.canRemove(live[0], inSession: false), "anything goes before starting")
    }

    func testAddedDuringSessionIsFiledByGrade() {
        XCTAssertEqual(KilterPlanProgress.goalForAdded(difficulty: 18, working: 20), .warmup)
        XCTAssertEqual(KilterPlanProgress.goalForAdded(difficulty: 20.2, working: 20), .send)
        XCTAssertEqual(KilterPlanProgress.goalForAdded(difficulty: 22, working: 20), .project)
        XCTAssertEqual(KilterPlanProgress.goalForAdded(difficulty: 30, working: nil), .send)
    }

    func testNextUpFollowsTheEditedOrder() {
        let out = KilterPlanProgress.adding(climb("w0"), as: .warmup, to: plan)
        XCTAssertEqual(KilterPlanProgress.nextPending(out)?.climbUUID, "w1", "added at the end of warm-ups, not first")
        let removedFirst = KilterPlanProgress.removing(id: plan[0].id, from: plan, inSession: true)
        XCTAssertEqual(KilterPlanProgress.nextPending(removedFirst)?.climbUUID, "w2")
    }
}
