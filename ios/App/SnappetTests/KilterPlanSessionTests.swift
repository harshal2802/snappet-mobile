import XCTest
import SwiftData
@testable import Snappet

/// Store-level tests for the planned-session half of `KilterSessionManager` — attach / tick /
/// orphan-close. Same harness as `KilterSessionAutoStartTests`: in-memory store, deliberately
/// **unbound** manager (store effects only; the live-HR / Live-Activity halves stay device-pending).
/// These pin the PR-02 review fixes: one open plan per session, and a plan never outliving its session.
@MainActor
final class KilterPlanSessionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    override func tearDown() { container = nil; super.tearDown() }

    private func makePlan(_ picks: [(String, KilterRecommender.Goal)]) -> KilterPlan {
        let items = picks.enumerated().map { i, p in
            KilterPlanItem(order: i, goal: p.1, climbUUID: p.0, climbName: p.0, setter: "S",
                           gradeLabel: "6a/V3", difficulty: 18)
        }
        return KilterPlan(angle: 40, layoutId: 1, items: items)
    }
    private func allPlans() throws -> [KilterPlan] { try context.fetch(FetchDescriptor<KilterPlan>()) }

    func testAttachPinsPlanToCurrentSession() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let plan = makePlan([("s1", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        XCTAssertEqual(plan.sessionId, m.currentId)
        XCTAssertEqual(m.currentPlanId, plan.id)
    }

    func testAttachClosesAPriorOpenPlanForTheSameSession() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let first = makePlan([("a", .send)]); context.insert(first)
        m.attachPlan(first, in: context)
        let second = makePlan([("b", .send)]); context.insert(second)
        m.attachPlan(second, in: context)
        // Invariant: at most one OPEN plan per session.
        let open = try allPlans().filter { $0.sessionId == m.currentId && $0.completedAt == nil }
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.id, second.id)
        XCTAssertNotNil(first.completedAt, "the superseded plan is closed, not left open")
    }

    func testApplyLogToPlanTicksMatchingItemOnly() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let plan = makePlan([("w", .warmup), ("s", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        m.applyLogToPlan(climbUUID: "s", ascent: .sent, at: .now, in: context)
        XCTAssertEqual(plan.items.first { $0.climbUUID == "s" }?.status, .sent)
        XCTAssertEqual(plan.items.first { $0.climbUUID == "w" }?.status, .pending)
    }

    func testApplyLogToPlanIgnoresOffPlanClimb() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let plan = makePlan([("s", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        m.applyLogToPlan(climbUUID: "not-in-plan", ascent: .sent, at: .now, in: context)
        XCTAssertTrue(plan.items.allSatisfy { $0.status == .pending })
    }

    func testEndClosesTheAttachedPlanNoOrphan() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let sid = try XCTUnwrap(m.currentId)
        let plan = makePlan([("s", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        m.end(sessionID: sid, in: context)
        XCTAssertNotNil(plan.completedAt, "ending the session closes its plan — no permanent orphan")
        XCTAssertNil(m.currentPlanId)
        XCTAssertNil(m.openPlan(forSession: sid, in: context), "no open plan remains for an ended session")
    }

    func testUndoStartDeletesTheAttachedPlan() throws {
        let m = KilterSessionManager()
        XCTAssertTrue(m.start(angle: 40, source: "manual", in: context))
        let plan = makePlan([("s", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        m.undoStart(in: context)
        XCTAssertTrue(try allPlans().isEmpty, "the plan must not outlive an undone session")
    }

    func testPlanProgressTracksAttachLogAndEnd() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let sid = try XCTUnwrap(m.currentId)
        let plan = makePlan([("w", .warmup), ("s", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        XCTAssertEqual(m.planProgress?.done, 0)
        XCTAssertEqual(m.planProgress?.total, 2)
        m.applyLogToPlan(climbUUID: "s", ascent: .sent, at: .now, in: context)
        XCTAssertEqual(m.planProgress?.done, 1)
        XCTAssertEqual(m.planProgress?.total, 2)
        m.end(sessionID: sid, in: context)
        XCTAssertNil(m.planProgress, "progress clears when the session ends (chip hides)")
    }

    func testNextPlanClimbFollowsTheForwardFlow() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let plan = makePlan([("w", .warmup), ("s", .send), ("p", .project)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        XCTAssertEqual(m.nextPlanClimb(excluding: "w"), "s")
        m.applyLogToPlan(climbUUID: "w", ascent: .sent, at: .now, in: context)
        XCTAssertEqual(m.nextPlanClimb(excluding: "s"), "p")
        m.applyLogToPlan(climbUUID: "s", ascent: .sent, at: .now, in: context)
        XCTAssertNil(m.nextPlanClimb(excluding: "p"))
    }

    /// Regression for the PR-05 review HIGH finding: tapping "Next pick" WITHOUT logging must keep
    /// advancing by plan order (w → s → p → done), not oscillate between the first two pending picks.
    func testNextPlanClimbAdvancesByOrderWithoutLogging() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let plan = makePlan([("w", .warmup), ("s", .send), ("p", .project)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        XCTAssertEqual(m.nextPlanClimb(excluding: "w"), "s")
        XCTAssertEqual(m.nextPlanClimb(excluding: "s"), "p", "must advance forward, not back to w")
        XCTAssertNil(m.nextPlanClimb(excluding: "p"), "last pending → Plan done")
        // An off-plan / already-resolved current climb falls back to the earliest pending pick.
        XCTAssertEqual(m.nextPlanClimb(excluding: "off-plan"), "w")
    }

    func testOpenPlanIgnoresClosedPlans() throws {
        let m = KilterSessionManager()
        m.start(angle: 40, source: "manual", in: context)
        let sid = try XCTUnwrap(m.currentId)
        let plan = makePlan([("s", .send)]); context.insert(plan)
        m.attachPlan(plan, in: context)
        XCTAssertEqual(m.openPlan(forSession: sid, in: context)?.id, plan.id)
        plan.completedAt = .now
        XCTAssertNil(m.openPlan(forSession: sid, in: context))
    }
}
