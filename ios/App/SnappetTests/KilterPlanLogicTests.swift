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

    /// A dense candidate pool spanning the bands around the working grade (≈18), so `recommend`
    /// always has climbs to draw on for every goal.
    private func candidatePool() -> [KilterListItem] {
        (14...22).flatMap { d in (0..<4).map { i in item("c\(d)-\(i)", Double(d)) } }
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

    func testPendingClimbUUIDsAreOrderedAndDropResolved() {
        var items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send), ("pr1", .project)]))
        XCTAssertEqual(KilterPlanProgress.pendingClimbUUIDs(items), ["w1", "s1", "pr1"])
        items = KilterPlanProgress.applyingLog(climbUUID: "s1", ascent: .sent, at: .now, to: items)
        XCTAssertEqual(KilterPlanProgress.pendingClimbUUIDs(items), ["w1", "pr1"])
    }

    func testSkippingDropsFromNextPendingButNotDone() {
        var items = KilterPlanProgress.items(from: plan([("w1", .warmup), ("s1", .send)]))
        let id = items.first { $0.climbUUID == "w1" }!.id
        items = KilterPlanProgress.skipping(id: id, in: items)
        XCTAssertEqual(items.first { $0.climbUUID == "w1" }?.status, .skipped)
        XCTAssertEqual(KilterPlanProgress.nextPending(items)?.climbUUID, "s1")
        XCTAssertEqual(KilterPlanProgress.progress(items).done, 0)
    }

    // MARK: - Selection strategy (PR 07)

    func testWeightedAllocationLeansAndSumsToTarget() {
        // Project-heavy mix on 5 climbs leans toward project, still sums to 5, ≥1 per weighted goal.
        let a = KilterRecommender.allocation(target: 5, mix: .init(warmup: 2, send: 1, project: 2))
        XCTAssertEqual(a.warmup + a.send + a.project, 5)
        XCTAssertGreaterThanOrEqual(a.warmup, 1)
        XCTAssertGreaterThanOrEqual(a.send, 1)
        XCTAssertGreaterThanOrEqual(a.project, 1)
        XCTAssertGreaterThanOrEqual(a.project, a.send, "project-leaning mix gives project ≥ send")
    }

    func testZeroWeightGoalIsDropped() {
        // Flash practice: no project. The project slot must be empty and the rest sum to target.
        let a = KilterRecommender.allocation(target: 6, mix: .init(warmup: 2, send: 4, project: 0))
        XCTAssertEqual(a.project, 0)
        XCTAssertEqual(a.warmup + a.send, 6)
        XCTAssertGreaterThan(a.send, a.warmup)
    }

    func testBalancedDefaultUnchangedByOptionalMix() {
        // A nil mix must reproduce the original allocation exactly (no behaviour drift).
        for t in 1...12 {
            let viaOptions = KilterRecommender.recommend(
                history: [], candidates: candidatePool(), anchor: 18,
                options: .init(targetCount: t, mix: nil))
            let viaDefault = KilterRecommender.recommend(
                history: [], candidates: candidatePool(), anchor: 18,
                options: .init(targetCount: t))
            XCTAssertEqual(viaOptions.picks.map(\.id), viaDefault.picks.map(\.id))
        }
    }

    func testEveryStrategyConfigIsCoherent() {
        for s in KilterRecommender.Strategy.allCases {
            let c = KilterRecommender.config(for: s)
            XCTAssertGreaterThanOrEqual(c.targetCount, 3)
            if s == .balanced { XCTAssertNil(c.mix) } else { XCTAssertNotNil(c.mix) }
        }
    }

    /// Property test (PR-07 review nicety): every real strategy mix, at every reachable session length,
    /// allocates exactly `targetCount` climbs with ≥1 per positive-weight goal and no negatives.
    func testEveryStrategyMixAllocatesCleanlyAcrossLengths() {
        for s in KilterRecommender.Strategy.allCases {
            guard let mix = KilterRecommender.config(for: s).mix else { continue }
            for t in 3...12 {
                let a = KilterRecommender.allocation(target: t, mix: mix)
                XCTAssertEqual(a.warmup + a.send + a.project, t, "\(s) @\(t) must sum to target")
                XCTAssertGreaterThanOrEqual(a.warmup, 0)
                XCTAssertGreaterThanOrEqual(a.send, 0)
                XCTAssertGreaterThanOrEqual(a.project, 0)
                if mix.warmup > 0 { XCTAssertGreaterThanOrEqual(a.warmup, 1, "\(s) @\(t) warmup ≥1") }
                if mix.send > 0 { XCTAssertGreaterThanOrEqual(a.send, 1, "\(s) @\(t) send ≥1") }
                if mix.project > 0 { XCTAssertGreaterThanOrEqual(a.project, 1, "\(s) @\(t) project ≥1") }
            }
        }
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
