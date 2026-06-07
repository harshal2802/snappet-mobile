import XCTest
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
