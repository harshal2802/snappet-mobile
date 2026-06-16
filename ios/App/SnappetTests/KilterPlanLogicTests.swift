import XCTest
@testable import Snappet

/// Pins the persisted-plan progress logic (`KilterPlanProgress`) — the keystone that replaces the old
/// "re-derive done-ness from logs ∩ recommend()" path. The headline test
/// (`testSendSectionPickStaysDoneAfterLog_regression`) reproduces the original defect's shape: logging
/// a send/project pick must mark it done AND keep it in place, where the recommender-rebuild path used
/// to drop the now-sent climb and reshuffle. Pure values only — no SwiftData, no device.
final class KilterPlanLogicTests: XCTestCase {

    private func item(_ uuid: String, _ diff: Double = 18, grade: String = "6a/V3") -> KilterListItem {
        KilterListItem(uuid: uuid, name: "Climb \(uuid)", setter: "Setter", difficulty: diff,
                       gradeLabel: grade, quality: 2.5, ascents: 100)
    }

    private func plan(_ picks: [(String, KilterRecommender.Goal)]) -> KilterRecommender.Plan {
        KilterRecommender.Plan(
            picks: picks.map { KilterRecommender.Pick(item: item($0.0), goal: $0.1) },
            workingDifficulty: 18, workingGradeLabel: "6a/V3")
    }

    func testItemsFromPlanPreserveOrderGoalsAndStartPending() {
        let items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send), ("pr1", .project)]))
        XCTAssertEqual(items.map(\.climbUUID), ["w1", "s1", "pr1"])
        XCTAssertEqual(items.map(\.order), [0, 1, 2])
        XCTAssertEqual(items.map(\.goal), [.warmup, .send, .project])
        XCTAssertTrue(items.allSatisfy { $0.status == .pending })
    }

    func testLoggingSendMarksMatchingPickSentAndLeavesOthers() {
        let items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send)]))
        let after = KilterPlanProgress.applyingLog(climbUUID: "s1", ascent: .sent, at: .now, to: items)
        XCTAssertEqual(after.first { $0.climbUUID == "s1" }?.status, .sent)
        XCTAssertNotNil(after.first { $0.climbUUID == "s1" }?.completedAt)
        XCTAssertEqual(after.first { $0.climbUUID == "w1" }?.status, .pending)
    }

    /// THE REGRESSION: a send in the Send/Project section marks that very pick done and it STAYS put —
    /// nothing is filtered out or reshuffled (the old `preferUnsent` rebuild dropped it).
    func testSendSectionPickStaysDoneAfterLog_regression() {
        let items = KilterPlanProgress.items(from: plan([("s1", .send), ("pr1", .project)]))
        let after = KilterPlanProgress.applyingLog(climbUUID: "pr1", ascent: .sent, at: .now, to: items)
        let pr = after.first { $0.climbUUID == "pr1" }
        XCTAssertNotNil(pr, "the project pick must still be present after sending it")
        XCTAssertEqual(pr?.status, .sent)
        XCTAssertEqual(after.count, items.count, "no pick vanished or got swapped in")
        XCTAssertEqual(after.map(\.climbUUID), items.map(\.climbUUID), "order is frozen")
    }

    func testAttemptMarksAttemptedThenSendUpgrades() {
        var items = KilterPlanProgress.items(from: plan([("s1", .send)]))
        items = KilterPlanProgress.applyingLog(climbUUID: "s1", ascent: .attempt, at: .now, to: items)
        XCTAssertEqual(items.first?.status, .attempted)
        items = KilterPlanProgress.applyingLog(climbUUID: "s1", ascent: .sent, at: .now, to: items)
        XCTAssertEqual(items.first?.status, .sent)
    }

    func testLoggingOffPlanClimbLeavesPlanUnchanged() {
        let items = KilterPlanProgress.items(from: plan([("s1", .send)]))
        let after = KilterPlanProgress.applyingLog(climbUUID: "ZZZ", ascent: .sent, at: .now, to: items)
        XCTAssertEqual(after, items)
    }

    func testProgressCountsDoneVsTotal() {
        var items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send), ("pr1", .project)]))
        items = KilterPlanProgress.applyingLog(climbUUID: "w1", ascent: .flash, at: .now, to: items)
        items = KilterPlanProgress.applyingLog(climbUUID: "s1", ascent: .attempt, at: .now, to: items)
        let pr = KilterPlanProgress.progress(items)
        XCTAssertEqual(pr.done, 2)
        XCTAssertEqual(pr.total, 3)
    }

    func testNextPendingIsLowestOrderPending() {
        var items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send), ("pr1", .project)]))
        XCTAssertEqual(KilterPlanProgress.nextPending(items)?.climbUUID, "w1")
        items = KilterPlanProgress.applyingLog(climbUUID: "w1", ascent: .sent, at: .now, to: items)
        XCTAssertEqual(KilterPlanProgress.nextPending(items)?.climbUUID, "s1")
    }

    func testSkippingDropsFromNextPendingButNotDone() {
        var items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send)]))
        let id = items.first { $0.climbUUID == "w1" }!.id
        items = KilterPlanProgress.skipping(id: id, in: items)
        XCTAssertEqual(items.first { $0.climbUUID == "w1" }?.status, .skipped)
        XCTAssertEqual(KilterPlanProgress.nextPending(items)?.climbUUID, "s1")
        XCTAssertEqual(KilterPlanProgress.progress(items).done, 0)
    }

    func testAllResolvedWhenNoPendingRemain() {
        var items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send)]))
        XCTAssertFalse(KilterPlanProgress.allResolved(items))
        items = KilterPlanProgress.applyingLog(climbUUID: "w1", ascent: .sent, at: .now, to: items)
        let sid = items.first { $0.climbUUID == "s1" }!.id
        items = KilterPlanProgress.skipping(id: sid, in: items)
        XCTAssertTrue(KilterPlanProgress.allResolved(items))
    }
}
