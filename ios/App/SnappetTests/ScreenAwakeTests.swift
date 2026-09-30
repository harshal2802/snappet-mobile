import XCTest
@testable import Snappet

/// Prompt 135: the workout screen auto-locked mid-session. The policy decides from (mode, holds); the
/// controller reference-counts named holds so one surface releasing can't turn auto-lock back on under
/// another that still needs the screen.
@MainActor
final class ScreenAwakeTests: XCTestCase {

    // MARK: - Policy

    func testWholeWorkoutKeepsAwakeForAnyHold() {
        XCTAssertTrue(ScreenAwakePolicy.shouldKeepAwake(mode: .wholeWorkout, holding: [.workout]))
        XCTAssertTrue(ScreenAwakePolicy.shouldKeepAwake(mode: .wholeWorkout, holding: [.timer]))
        XCTAssertFalse(ScreenAwakePolicy.shouldKeepAwake(mode: .wholeWorkout, holding: []))
    }

    func testTimersOnlyIgnoresTheOpenPlayer() {
        XCTAssertFalse(ScreenAwakePolicy.shouldKeepAwake(mode: .timersOnly, holding: [.workout]))
        XCTAssertTrue(ScreenAwakePolicy.shouldKeepAwake(mode: .timersOnly, holding: [.workout, .timer]))
    }

    func testOffNeverOverridesAutoLock() {
        XCTAssertFalse(ScreenAwakePolicy.shouldKeepAwake(mode: .off, holding: [.workout, .timer]))
    }

    func testModeResolveFallsBackToDefault() {
        XCTAssertEqual(KeepScreenAwakeMode.resolve(nil), .wholeWorkout)
        XCTAssertEqual(KeepScreenAwakeMode.resolve("garbage"), .wholeWorkout)
        XCTAssertEqual(KeepScreenAwakeMode.resolve("timersOnly"), .timersOnly)
    }

    // MARK: - Controller

    private func makeController(_ mode: KeepScreenAwakeMode) -> (ScreenAwakeController, () -> Bool?) {
        var last: Bool?
        let c = ScreenAwakeController(mode: mode, apply: { last = $0 })
        return (c, { last })
    }

    /// The reported bug: a timed cover over the open player used to write `false` on dismiss.
    func testClosingATimedCoverKeepsTheWorkoutAwake() {
        let (c, flag) = makeController(.wholeWorkout)
        c.hold("workoutPlayer", reason: .workout)
        c.hold("timedSetCover", reason: .timer)
        c.release("timedSetCover")
        XCTAssertEqual(flag(), true)
        c.release("workoutPlayer")
        XCTAssertEqual(flag(), false)
    }

    func testReleaseOrderDoesNotMatter() {
        let (c, flag) = makeController(.wholeWorkout)
        c.hold("a", reason: .timer)
        c.hold("b", reason: .timer)
        c.release("a")
        XCTAssertEqual(flag(), true)
        c.release("b")
        XCTAssertEqual(flag(), false)
    }

    func testHoldIsIdempotentPerID() {
        let (c, flag) = makeController(.wholeWorkout)
        c.hold("restTimer", reason: .timer)
        c.hold("restTimer", reason: .timer)
        c.release("restTimer")
        XCTAssertEqual(flag(), false)
    }

    func testChangingModeReappliesImmediately() {
        let (c, flag) = makeController(.wholeWorkout)
        c.hold("workoutPlayer", reason: .workout)
        XCTAssertEqual(flag(), true)
        c.mode = .timersOnly
        XCTAssertEqual(flag(), false)
        c.set("restTimer", reason: .timer, active: true)
        XCTAssertEqual(flag(), true)
        c.mode = .off
        XCTAssertEqual(flag(), false)
    }

    func testReleasingAnUnknownHoldIsANoOp() {
        var applies = 0
        let c = ScreenAwakeController(mode: .wholeWorkout, apply: { _ in applies += 1 })
        c.release("never-held")
        XCTAssertEqual(applies, 0)
    }
}
