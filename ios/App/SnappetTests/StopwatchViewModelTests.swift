import XCTest
@testable import Snappet

/// The frozen-timer family (#271): a host tears the display ticker down in `onDisappear` (a
/// full-screen cover — e.g. the RecordClipButton camera — removes the host from the hierarchy),
/// and the run itself survives, so `start()` alone no-ops on reappear and the digits freeze.
/// These pin the ticker/run-state contract (`isTicking` vs `isRunning`) without sleeping on
/// real ticks, so the covers' `resumeTicking()`-on-appear fix can't silently regress.
@MainActor
final class StopwatchViewModelTests: XCTestCase {

    func testStartRunsTicker() {
        let vm = StopwatchViewModel(mode: .countUp)
        XCTAssertFalse(vm.isTicking)
        vm.start()
        XCTAssertTrue(vm.isRunning)
        XCTAssertTrue(vm.isTicking)
    }

    func testEndTickingKeepsRunAlive_startAloneDoesNotRestartTicker() {
        let vm = StopwatchViewModel(mode: .countUp)
        vm.start()
        vm.endTicking()                       // the onDisappear teardown (camera cover presented)
        XCTAssertTrue(vm.isRunning, "the wall-clock run survives the display teardown")
        XCTAssertFalse(vm.isTicking)
        vm.start()                            // what the covers' onAppear did before the fix
        XCTAssertFalse(vm.isTicking, "start() no-ops on a live run — the pre-fix frozen display")
        vm.resumeTicking()                    // the fix
        XCTAssertTrue(vm.isTicking)
    }

    func testResumeTickingIsSafeWhenNotRunningOrAlreadyTicking() {
        let vm = StopwatchViewModel(mode: .countUp)
        vm.resumeTicking()
        XCTAssertFalse(vm.isTicking, "no run → nothing to resume")
        vm.start()
        vm.resumeTicking()
        XCTAssertTrue(vm.isTicking, "already ticking → a no-op, not a second ticker")
        _ = vm.stop()
        XCTAssertFalse(vm.isTicking, "stop tears the ticker down with the run")
        XCTAssertFalse(vm.isRunning)
    }
}
