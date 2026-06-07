import XCTest
@testable import Snappet

/// Unit tests for the **pure** Kilter Live Activity throttle `KilterLiveSnapshot.shouldPush` — no
/// ActivityKit, no device. Mirrors `WorkoutLiveSnapshot`'s contract: structural changes push
/// immediately; HR-only changes are rate-limited.
final class KilterLiveSnapshotTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func snap(hr: Int?, climb: String = "Alpha", grade: String = "6a/V3",
                      count: Int = 1, paused: Bool = false) -> KilterLiveSnapshot {
        KilterLiveSnapshot(startedAt: t0, hrBpm: hr, currentClimbName: climb,
                           currentGrade: grade, climbCount: count, paused: paused)
    }

    func testFirstPushAlwaysGoes() {
        XCTAssertTrue(KilterLiveSnapshot.shouldPush(snap(hr: 120), after: nil,
                                                    lastPushedAt: nil, now: t0))
    }

    func testClimbChangePushesImmediately() {
        let last = snap(hr: 120, climb: "Alpha")
        let next = snap(hr: 120, climb: "Bravo")
        XCTAssertTrue(KilterLiveSnapshot.shouldPush(next, after: last,
                                                    lastPushedAt: t0, now: t0.addingTimeInterval(0.1)))
    }

    func testClimbCountChangePushesImmediately() {
        let last = snap(hr: 120, count: 1)
        let next = snap(hr: 120, count: 2)
        XCTAssertTrue(KilterLiveSnapshot.shouldPush(next, after: last,
                                                    lastPushedAt: t0, now: t0.addingTimeInterval(0.1)))
    }

    func testPauseChangePushesImmediately() {
        let last = snap(hr: 120, paused: false)
        let next = snap(hr: 120, paused: true)
        XCTAssertTrue(KilterLiveSnapshot.shouldPush(next, after: last,
                                                    lastPushedAt: t0, now: t0.addingTimeInterval(0.1)))
    }

    func testIdenticalDoesNotPush() {
        let last = snap(hr: 120)
        XCTAssertFalse(KilterLiveSnapshot.shouldPush(last, after: last,
                                                     lastPushedAt: t0, now: t0.addingTimeInterval(5)))
    }

    func testHROnlyChangeIsRateLimited() {
        let last = snap(hr: 120)
        let next = snap(hr: 130)
        // Within the 2s window → suppressed.
        XCTAssertFalse(KilterLiveSnapshot.shouldPush(next, after: last,
                                                     lastPushedAt: t0, now: t0.addingTimeInterval(1)))
        // After the window → allowed.
        XCTAssertTrue(KilterLiveSnapshot.shouldPush(next, after: last,
                                                    lastPushedAt: t0, now: t0.addingTimeInterval(2)))
    }
}
