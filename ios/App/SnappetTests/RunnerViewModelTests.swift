import XCTest
@testable import Snappet

/// Prompts 141 + 143 — the runner's time accounting with a controlled clock: tap-done reps, and that a
/// mid-run adjustment never double-counts or loses time under tension.
@MainActor
final class RunnerViewModelTests: XCTestCase {

    private final class Clock { var t = Date(timeIntervalSince1970: 1_000) }

    private func runner(_ spec: TimedExerciseSpec) -> (RunnerViewModel, Clock) {
        let clock = Clock()
        let vm = RunnerViewModel(spec: spec, clock: { clock.t })
        vm.start()
        vm.endTicking()   // drive time by hand
        return (vm, clock)
    }

    private func advance(_ vm: RunnerViewModel, _ clock: Clock, by s: TimeInterval) {
        clock.t = clock.t.addingTimeInterval(s)
        vm.syncToWallClock()
    }

    func testPlainRunCountsTheCompletedHang() {
        let (vm, clock) = runner(.maxHangs)      // 5 s lead-in, 7 s hang
        advance(vm, clock, by: 12)
        XCTAssertEqual(vm.capture.tut, 7, accuracy: 0.001)
        XCTAssertEqual(vm.capture.completedReps, 1)
    }

    func testAdjustMidHangDoesNotDoubleCountIt() {
        let (vm, clock) = runner(.maxHangs)
        advance(vm, clock, by: 8)                 // 3 s into the first hang
        var loaded = TimedExerciseSpec.maxHangs
        loaded.load = HangLoad(kind: .added, amount: 5)
        vm.adjust(to: loaded)
        XCTAssertEqual(vm.state.phase.kind, .work, "the hang continues")
        XCTAssertEqual(vm.state.remainingInPhase, 4)
        advance(vm, clock, by: 4)                 // hang ends
        XCTAssertEqual(vm.capture.tut, 7, accuracy: 0.001, "3 s before + 4 s after = one 7 s hang")
        XCTAssertEqual(vm.capture.completedReps, 1)
        XCTAssertTrue(vm.hasChanges)
        XCTAssertEqual(vm.buildSetLog().loadKg, 5)
    }

    func testAdjustDuringRestCountsEarlierWorkOnce() {
        let (vm, clock) = runner(.maxHangs)
        advance(vm, clock, by: 22)                // hang done (12), 10 s into the 120 s rest
        var longer = TimedExerciseSpec.maxHangs
        longer.restSec = 180
        vm.adjust(to: longer)
        XCTAssertEqual(vm.state.remainingInPhase, 110, "the rest in progress keeps its time")
        advance(vm, clock, by: 110 + 7)           // rest ends, second hang completes
        XCTAssertEqual(vm.capture.tut, 14, accuracy: 0.001)
        XCTAssertEqual(vm.capture.completedReps, 2)
        advance(vm, clock, by: 1)
        XCTAssertEqual(vm.state.remainingInPhase, 179, "the next rest is the new length")
    }

    func testTapDoneRepTimesTheRepThenRests() {
        let (vm, clock) = runner(.contact)        // 5 s lead-in, open rep, 30 s rest
        advance(vm, clock, by: 5)
        XCTAssertTrue(vm.state.phase.isOpenEnded)
        advance(vm, clock, by: 40)                // a long rep — never times out
        XCTAssertTrue(vm.state.phase.isOpenEnded)
        XCTAssertEqual(vm.openRepElapsed ?? 0, 40, accuracy: 0.001)
        vm.completeOpenRep()
        XCTAssertEqual(vm.state.phase.kind, .rest)
        XCTAssertEqual(vm.state.remainingInPhase, 30, "the rest starts in full after DONE")
        XCTAssertEqual(vm.capture.tut, 40, accuracy: 0.001)
        XCTAssertEqual(vm.capture.completedReps, 1)
    }

    func testAdjustDuringATapDoneRepKeepsTheRepRunning() {
        let (vm, clock) = runner(.contact)
        advance(vm, clock, by: 5)
        advance(vm, clock, by: 2)
        var longer = TimedExerciseSpec.contact
        longer.restSec = 45
        vm.adjust(to: longer)
        XCTAssertTrue(vm.state.phase.isOpenEnded)
        XCTAssertEqual(vm.openRepElapsed ?? 0, 2, accuracy: 0.001)
        advance(vm, clock, by: 1)
        vm.completeOpenRep()
        XCTAssertEqual(vm.capture.tut, 3, accuracy: 0.001)
        XCTAssertEqual(vm.state.remainingInPhase, 45)
    }

    func testSkippingTheLastRestDoesNotSkipTheFinalTapDoneRep() {
        var oneSet = TimedExerciseSpec.contact
        oneSet.sets = 1
        oneSet.reps = 2                           // rep · rest · rep
        let (vm, clock) = runner(oneSet)
        advance(vm, clock, by: 5)
        vm.completeOpenRep()
        vm.skipPhase()                            // skip the only rest
        XCTAssertFalse(vm.isFinished, "the last rep is still to do")
        advance(vm, clock, by: 0.5)
        XCTAssertTrue(vm.state.phase.isOpenEnded)
    }

    // MARK: - Force sensor (prompt 145)

    private func feed(_ vm: RunnerViewModel, _ clock: Clock, kg: Double, for seconds: Double, hz: Double = 10) {
        let n = Int(seconds * hz)
        for _ in 0..<n {
            clock.t = clock.t.addingTimeInterval(1 / hz)
            vm.ingestForce(ForceSample(t: 0, kg: kg))
            vm.syncToWallClock()
        }
    }

    func testATimedHangWaitsForLoadThenRuns() {
        let (vm, clock) = runner(.maxHangs)
        vm.forceGatingEnabled = true
        advance(vm, clock, by: 5)                       // lead-in over → first hang
        XCTAssertTrue(vm.isWaitingForLoad)
        advance(vm, clock, by: 10)                      // nobody on the edge yet
        XCTAssertTrue(vm.isWaitingForLoad)
        XCTAssertEqual(vm.state.remainingInPhase, 7, "the hang's clock hasn't started")
        feed(vm, clock, kg: 46, for: 7.3)               // load → the 7 s hang runs from that moment
        XCTAssertFalse(vm.isWaitingForLoad)
        XCTAssertEqual(vm.state.phase.kind, .rest)
        XCTAssertEqual(vm.capture.tut, 7, accuracy: 0.15)
    }

    func testATapDoneRepFinishesWhenYouLetGo() {
        let (vm, clock) = runner(.contact)
        vm.forceGatingEnabled = true
        advance(vm, clock, by: 5)
        XCTAssertTrue(vm.state.phase.isOpenEnded)
        feed(vm, clock, kg: 40, for: 2)
        feed(vm, clock, kg: 0.5, for: 0.2)              // let go
        XCTAssertEqual(vm.state.phase.kind, .rest, "release ended the rep")
        XCTAssertEqual(vm.capture.completedReps, 1)
    }

    func testEachHangIsMeasuredAndLogged() {
        let (vm, clock) = runner(.maxHangs)
        advance(vm, clock, by: 5)
        feed(vm, clock, kg: 46, for: 6.8)
        feed(vm, clock, kg: 0.3, for: 1)                // into the rest
        let log = vm.buildSetLog()
        XCTAssertEqual(log.forceReps?.count, 1)
        XCTAssertEqual(log.forceReps?.first?.peakKg ?? 0, 46, accuracy: 0.1)
        XCTAssertEqual(log.forceReps?.first?.holdSec ?? 0, 6.7, accuracy: 0.3)
        XCTAssertEqual(log.forceReps?.first?.set, 1)
    }

    func testTurningGatingOffMidHoldResumesOnTheTimer() {
        let (vm, clock) = runner(.maxHangs)
        vm.forceGatingEnabled = true
        advance(vm, clock, by: 5)
        XCTAssertTrue(vm.isWaitingForLoad)
        vm.forceGatingEnabled = false                    // e.g. the sensor dropped
        XCTAssertFalse(vm.isWaitingForLoad)
        advance(vm, clock, by: 7)
        XCTAssertEqual(vm.state.phase.kind, .rest)
    }

    /// Letting go partway through a timed hang ends it short — it must not re-hold the hang (that froze the
    /// clock at the hang's start and erased the seconds already done; caught on the UI-test end card).
    func testLettingGoMidHangDoesNotReHoldIt() {
        let (vm, clock) = runner(.maxHangs)
        vm.forceGatingEnabled = true
        feed(vm, clock, kg: 46, for: 5)                 // loaded through the lead-in
        XCTAssertEqual(vm.state.phase.kind, .work)
        XCTAssertFalse(vm.isWaitingForLoad, "already loaded as the hang began")
        feed(vm, clock, kg: 46, for: 2)
        feed(vm, clock, kg: 0.3, for: 1)                // let go 2 s in
        XCTAssertFalse(vm.isWaitingForLoad)
        XCTAssertGreaterThan(vm.capture.tut, 2.5, "the time already hung is kept")
    }
}
