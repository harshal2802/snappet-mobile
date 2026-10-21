import XCTest
@testable import Snappet

/// Which Live Activities stay on the Lock Screen (prompt 198): the running session's — every other is an orphan.
final class LiveActivityReconcileTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoSessionRunningEndsEverything() {
        let plan = LiveActivityReconcile.plan(running: [.init(id: "a", startedAt: t0), .init(id: "b", startedAt: t0)],
                                              activeSessionStartedAt: nil)
        XCTAssertNil(plan.keep)
        XCTAssertEqual(plan.end, ["a", "b"])
    }

    func testTheRunningSessionsActivityIsKeptAndTheOrphanEnded() {
        // A crash left yesterday's activity; today's session is running with its own.
        let plan = LiveActivityReconcile.plan(
            running: [.init(id: "old", startedAt: t0.addingTimeInterval(-86_400)), .init(id: "now", startedAt: t0)],
            activeSessionStartedAt: t0.addingTimeInterval(0.4))
        XCTAssertEqual(plan.keep, "now", "same start, to the second")
        XCTAssertEqual(plan.end, ["old"])
    }

    func testAResumeAdoptsTheActivityInsteadOfStartingASecond() {
        let plan = LiveActivityReconcile.plan(running: [.init(id: "mine", startedAt: t0)], activeSessionStartedAt: t0)
        XCTAssertEqual(plan, .init(keep: "mine", end: []))
    }

    func testNothingRunningNothingToDo() {
        XCTAssertEqual(LiveActivityReconcile.plan(running: [], activeSessionStartedAt: t0), .init(keep: nil, end: []))
    }
}
