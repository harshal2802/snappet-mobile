import XCTest
@testable import Snappet

/// Unit tests for the **pure** `StopwatchTiming` math — elapsed-with-pause, count-down clamp, and the
/// reached-zero edge — no view, no device. (workout-with-timer PR 1, prompt 59)
final class StopwatchTimingTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Count up

    func testCountUpElapsedFromAnchor() {
        let r = StopwatchTiming.reading(startedAt: t0, accumulated: 0,
                                        now: t0.addingTimeInterval(42), mode: .countUp)
        XCTAssertEqual(r.elapsed, 42, accuracy: 0.001)
        XCTAssertNil(r.remaining)
        XCTAssertFalse(r.reachedZero)
    }

    func testCountUpNotRunningUsesAccumulatedOnly() {
        // startedAt == nil → only the banked time counts (the stopped/paused display).
        let r = StopwatchTiming.reading(startedAt: nil, accumulated: 30, now: t0, mode: .countUp)
        XCTAssertEqual(r.elapsed, 30, accuracy: 0.001)
    }

    func testElapsedNeverNegativeIfClockGoesBackwards() {
        let r = StopwatchTiming.reading(startedAt: t0, accumulated: 0,
                                        now: t0.addingTimeInterval(-5), mode: .countUp)
        XCTAssertEqual(r.elapsed, 0, accuracy: 0.001)
    }

    // MARK: - Pause / resume (freeze)

    func testFreezeThenResumeAccumulatesWithoutLosingOrDoubleCounting() {
        // Run 10s, freeze → banked 10s.
        let banked = StopwatchTiming.freeze(startedAt: t0, accumulated: 0, now: t0.addingTimeInterval(10))
        XCTAssertEqual(banked, 10, accuracy: 0.001)
        // Resume with a fresh anchor at an arbitrary later wall time, run 5s more → total 15s
        // (not 5, not 25).
        let resumeAnchor = t0.addingTimeInterval(100)
        let r = StopwatchTiming.reading(startedAt: resumeAnchor, accumulated: banked,
                                        now: resumeAnchor.addingTimeInterval(5), mode: .countUp)
        XCTAssertEqual(r.elapsed, 15, accuracy: 0.001)
    }

    func testFreezeIsClampedNonNegative() {
        let banked = StopwatchTiming.freeze(startedAt: t0, accumulated: 0, now: t0.addingTimeInterval(-3))
        XCTAssertEqual(banked, 0, accuracy: 0.001)
    }

    // MARK: - Count down

    func testCountDownRemainingMidway() {
        let r = StopwatchTiming.reading(startedAt: t0, accumulated: 0,
                                        now: t0.addingTimeInterval(20), mode: .countDown(targetSec: 45))
        XCTAssertEqual(r.remaining ?? -1, 25, accuracy: 0.001)
        XCTAssertFalse(r.reachedZero)
        XCTAssertEqual(r.elapsed, 20, accuracy: 0.001)
    }

    func testCountDownClampsAtZeroAndFlipsReachedZero() {
        let r = StopwatchTiming.reading(startedAt: t0, accumulated: 0,
                                        now: t0.addingTimeInterval(60), mode: .countDown(targetSec: 45))
        XCTAssertEqual(r.remaining ?? -1, 0, accuracy: 0.001)   // clamped, never negative
        XCTAssertTrue(r.reachedZero)
        XCTAssertEqual(r.elapsed, 60, accuracy: 0.001)          // elapsed keeps counting past the target
    }

    func testCountDownReachedZeroExactlyAtTarget() {
        let r = StopwatchTiming.reading(startedAt: t0, accumulated: 0,
                                        now: t0.addingTimeInterval(30), mode: .countDown(targetSec: 30))
        XCTAssertTrue(r.reachedZero)
        XCTAssertEqual(r.remaining ?? -1, 0, accuracy: 0.001)
    }

    func testCountDownFullAtStart() {
        let r = StopwatchTiming.reading(startedAt: nil, accumulated: 0, now: t0,
                                        mode: .countDown(targetSec: 45))
        XCTAssertEqual(r.remaining ?? -1, 45, accuracy: 0.001)
        XCTAssertFalse(r.reachedZero)
    }
}
