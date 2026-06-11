import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the **pure** `KilterSessionRecovery` planner — the single-open-session invariant +
/// abandoned-session auto-close that keep the in-memory `KilterSessionManager` and the persisted store
/// from drifting (the fix for the "session goes stale after navigating" bug). No SwiftData, no device.
final class KilterSessionRecoveryTests: XCTestCase {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
    }
    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
    private typealias C = KilterSessionRecovery.Candidate
    private typealias Close = KilterSessionRecovery.Closure

    func testEmptyIsEmptyPlan() {
        XCTAssertEqual(KilterSessionRecovery.plan(open: [], now: t(10_000)), .empty)
    }

    func testSingleRecentIsAdopted() {
        let a = C(id: id(1), startedAt: t(9_000), lastActivity: t(9_900))
        let p = KilterSessionRecovery.plan(open: [a], now: t(10_000))
        XCTAssertEqual(p.adopt, id(1))
        XCTAssertTrue(p.close.isEmpty)
    }

    func testSingleAbandonedIsClosedNotAdopted() {
        let a = C(id: id(1), startedAt: t(500), lastActivity: t(1_000))
        let p = KilterSessionRecovery.plan(open: [a], now: t(100_000))   // idle ~99k s ≫ 6h
        XCTAssertNil(p.adopt)
        XCTAssertEqual(p.close, [Close(id: id(1), endedAt: t(1_000))])
    }

    func testNewestAdoptedOthersClosedAtTheirLastActivity() {
        let a = C(id: id(1), startedAt: t(1_000), lastActivity: t(9_000))
        let b = C(id: id(2), startedAt: t(2_000), lastActivity: t(9_500))
        let c = C(id: id(3), startedAt: t(3_000), lastActivity: t(9_900))   // newest start, still live
        let p = KilterSessionRecovery.plan(open: [a, b, c], now: t(10_000))
        XCTAssertEqual(p.adopt, id(3))
        XCTAssertEqual(Set(p.close),
                       [Close(id: id(1), endedAt: t(9_000)), Close(id: id(2), endedAt: t(9_500))])
    }

    func testAllAbandonedClosedNoneAdopted() {
        let a = C(id: id(1), startedAt: t(1_000), lastActivity: t(5_000))
        let b = C(id: id(2), startedAt: t(2_000), lastActivity: t(6_000))
        let c = C(id: id(3), startedAt: t(3_000), lastActivity: t(7_000))
        let p = KilterSessionRecovery.plan(open: [a, b, c], now: t(100_000))
        XCTAssertNil(p.adopt)
        XCTAssertEqual(Set(p.close),
                       [Close(id: id(1), endedAt: t(5_000)),
                        Close(id: id(2), endedAt: t(6_000)),
                        Close(id: id(3), endedAt: t(7_000))])
    }

    func testTieBreakByIdWhenSameStart() {
        let a = C(id: id(1), startedAt: t(3_000), lastActivity: t(9_000))
        let b = C(id: id(2), startedAt: t(3_000), lastActivity: t(9_000))
        let p = KilterSessionRecovery.plan(open: [a, b], now: t(10_000))
        XCTAssertEqual(p.adopt, id(2))   // higher uuid wins a same-start tie (deterministic)
        XCTAssertEqual(p.close, [Close(id: id(1), endedAt: t(9_000))])
    }

    func testClosureNeverStampsBeforeStart() {
        // Defensive: a lastActivity that somehow precedes startedAt must clamp to startedAt (no negative
        // duration / inverted media window).
        let a = C(id: id(1), startedAt: t(5_000), lastActivity: t(1_000))
        let p = KilterSessionRecovery.plan(open: [a], now: t(100_000))
        XCTAssertEqual(p.close, [Close(id: id(1), endedAt: t(5_000))])   // max(5000, 1000)
    }

    func testAbandonThresholdBoundary() {
        // Exactly at the threshold counts as still-live (adopted); just past it is abandoned.
        let live = C(id: id(1), startedAt: t(0), lastActivity: t(0))
        XCTAssertEqual(KilterSessionRecovery.plan(open: [live], now: t(6 * 3600), abandonedAfter: 6 * 3600).adopt, id(1))
        let dead = C(id: id(2), startedAt: t(0), lastActivity: t(0))
        XCTAssertNil(KilterSessionRecovery.plan(open: [dead], now: t(6 * 3600 + 1), abandonedAfter: 6 * 3600).adopt)
    }
}

/// `KilterSessionManager.start` folds a `recover(in:)` pass in front of session creation (#71
/// pre-merge review), so the stale-session policy above applies on EVERY path that can start a
/// session — including deep links that skip `KilterRootView.onAppear` (Home → "Plan tonight's
/// session"). These tests exercise that fold against an in-memory store with an **unbound**
/// manager (no live services — exactly the state the review feared), asserting store effects
/// only; the live-HR / Live-Activity halves stay device-pending per the repo pattern.
@MainActor
final class KilterSessionStartRecoveryTests: XCTestCase {
    /// Kept as a property: a `ModelContext` does NOT retain its `ModelContainer`, so letting the
    /// container deallocate makes every later SwiftData call trap (the documented gotcha).
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func openSessions() throws -> [KilterSession] {
        try context.fetch(FetchDescriptor<KilterSession>(predicate: #Predicate { $0.endedAt == nil }))
    }

    func testStartAdoptsFreshOpenSessionInsteadOfForking() throws {
        let open = KilterSession(startedAt: .now.addingTimeInterval(-600), angle: 40, source: "manual")
        context.insert(open)
        try context.save()

        let manager = KilterSessionManager()
        manager.start(angle: 45, source: "manual", in: context)

        XCTAssertEqual(manager.currentId, open.id)          // adopted, not forked
        XCTAssertEqual(try openSessions().count, 1)         // single-open invariant holds
    }

    func testStartAutoClosesAbandonedOpenSessionThenStartsFresh() throws {
        // Idle ~48 h ≫ the 6 h abandon threshold; no logs, so lastActivity == startedAt.
        let stale = KilterSession(startedAt: .now.addingTimeInterval(-48 * 3600), angle: 40, source: "ble")
        context.insert(stale)
        try context.save()

        let manager = KilterSessionManager()
        manager.start(angle: 45, source: "manual", in: context)

        XCTAssertNotNil(manager.currentId)
        XCTAssertNotEqual(manager.currentId, stale.id)      // a fresh session, not the orphan
        XCTAssertEqual(stale.endedAt, stale.startedAt)      // stamped at last activity, not "now"
        XCTAssertEqual(try openSessions().count, 1)
        XCTAssertEqual(try openSessions().first?.angle, 45) // the new session, with start's args
    }

    func testStartClosesDuplicateOpensAndAdoptsNewest() throws {
        let older = KilterSession(startedAt: .now.addingTimeInterval(-3_000), angle: 40, source: "manual")
        let newer = KilterSession(startedAt: .now.addingTimeInterval(-300), angle: 50, source: "ble")
        context.insert(older)
        context.insert(newer)
        try context.save()

        let manager = KilterSessionManager()
        manager.start(angle: 45, source: "manual", in: context)

        XCTAssertEqual(manager.currentId, newer.id)         // newest open wins
        XCTAssertNotNil(older.endedAt)                      // the duplicate is auto-closed
        XCTAssertEqual(try openSessions().count, 1)
    }

    func testStartIsNoOpWhileASessionIsAlreadyCurrent() throws {
        let manager = KilterSessionManager()
        manager.start(angle: 40, source: "manual", in: context)
        let first = manager.currentId
        XCTAssertNotNil(first)

        manager.start(angle: 50, source: "ble", in: context)   // second start must not fork

        XCTAssertEqual(manager.currentId, first)
        XCTAssertEqual(try openSessions().count, 1)
    }
}
