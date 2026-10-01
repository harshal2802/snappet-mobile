import XCTest
@testable import Snappet

/// Prompt 143 — adjusting a protocol mid-run: where the run continues in the rebuilt timeline, the
/// "You changed" list, and where "Keep for next time" saves.
final class RunnerAdjustTests: XCTestCase {

    /// Max hangs: lead-in 5 · [W7 R120 W7 R120 W7] × 3 with 240 between sets.
    private let base = TimedExerciseSpec.maxHangs

    private func at(_ spec: TimedExerciseSpec, _ t: Double) -> IntervalSchedule.State {
        IntervalSchedule(spec: spec).state(at: t)
    }

    func testLongerRestKeepsTheRestInProgressThenAppliesNext() {
        // 30 s into the first rest (starts at 12): 90 s left.
        let st = at(base, 42)
        XCTAssertEqual(st.phase.kind, .rest)
        XCTAssertEqual(st.remainingInPhase, 90)
        var longer = base; longer.restSec = 180
        let new = IntervalSchedule(spec: longer)
        let map = IntervalSchedule(spec: base).remap(current: st, to: new)
        let after = new.state(at: map.scheduleElapsed)
        XCTAssertEqual(after.phase.kind, .rest)
        XCTAssertEqual([after.setIndex, after.repIndex], [1, 1], "still the same rest")
        XCTAssertEqual(after.remainingInPhase, 90, "the rest in progress keeps its time")
        // The NEXT rest is the new length.
        let nextRestStart = map.scheduleElapsed + 90 + 7
        XCTAssertEqual(new.state(at: nextRestStart).remainingInPhase, 180)
    }

    func testShorterRestCapsTheRestInProgress() {
        let st = at(base, 22)   // 10 s into the first rest, 110 s left
        var shorter = base; shorter.restSec = 60
        let new = IntervalSchedule(spec: shorter)
        let map = IntervalSchedule(spec: base).remap(current: st, to: new)
        XCTAssertEqual(new.state(at: map.scheduleElapsed).remainingInPhase, 60, "capped at the new length")
    }

    func testFewerRepsDuringAVanishedRepJumpsToTheSetsEnd() {
        // Set 1, rep 3's work starts at 5 + 7 + 120 + 7 + 120 = 259. Be 2 s into it... then cut to 2 reps.
        let st = at(base, 261)
        XCTAssertEqual([st.setIndex, st.repIndex], [1, 3])
        var twoReps = base; twoReps.reps = 2
        let new = IntervalSchedule(spec: twoReps)
        let map = IntervalSchedule(spec: base).remap(current: st, to: new)
        let after = new.state(at: map.scheduleElapsed)
        XCTAssertEqual(after.phase.kind, .restBetweenSets, "rep 3 no longer exists — straight to the set rest")
        XCTAssertEqual(after.setIndex, 1)
        XCTAssertEqual(after.remainingInPhase, 240)
    }

    func testAddingLoadMidHangKeepsTheHang() {
        let st = at(base, 8)   // 3 s into the first hang
        var loaded = base; loaded.load = HangLoad(kind: .added, amount: 12.5)
        let new = IntervalSchedule(spec: loaded)
        let map = IntervalSchedule(spec: base).remap(current: st, to: new)
        let after = new.state(at: map.scheduleElapsed)
        XCTAssertEqual(after.phase.kind, .work)
        XCTAssertEqual(after.remainingInPhase, st.remainingInPhase)
        XCTAssertEqual(map.countFrom, 5, "work from this hang on counts under the new protocol")
    }

    func testSwitchingToOneHandContinuesAtTheNextSetStart() {
        let st = at(base, 300)   // set 1's between-set rest
        XCTAssertEqual(st.phase.kind, .restBetweenSets)
        var leftOnly = base; leftOnly.handMode = .leftOnly
        let new = IntervalSchedule(spec: leftOnly)
        let map = IntervalSchedule(spec: base).remap(current: st, to: new)
        XCTAssertEqual(new.state(at: map.scheduleElapsed).phase.kind, .restBetweenSets)
        let nextHang = new.state(at: map.scheduleElapsed + Double(st.remainingInPhase))
        XCTAssertEqual(nextHang.phase.hand, .left)
    }

    func testOpenRepCountIsCarriedIntoTheNewTimeline() {
        let contact = TimedExerciseSpec.contact
        let s = IntervalSchedule(spec: contact)
        let st = s.state(at: 35, completedOpenReps: 1)   // rep 2 of set 1 is open
        XCTAssertTrue(st.phase.isOpenEnded)
        var more = contact; more.restSec = 45
        let map = s.remap(current: st, to: IntervalSchedule(spec: more))
        XCTAssertEqual(map.openRepsBefore, 1)
        XCTAssertTrue(IntervalSchedule(spec: more).state(at: map.scheduleElapsed, completedOpenReps: 1).phase.isOpenEnded)
    }

    // MARK: - Change list + keep target

    func testChangeLines() {
        var new = base
        new.load = HangLoad(kind: .added, amount: 12.5)
        new.restSec = 90
        XCTAssertEqual(ProtocolChanges.lines(from: base, to: new),
                       ["Load: bodyweight → +12.5 kg", "Rest between reps: 2 min → 1:30"])
        XCTAssertEqual(ProtocolChanges.lines(from: base, to: base), [])
    }

    func testKeepTargetPrefersTheRoutineThenThePreset() {
        let preset = UUID()
        XCTAssertEqual(ProtocolKeepTarget.presetID(fromExerciseId: "timed:\(preset.uuidString)"), preset)
        XCTAssertNil(ProtocolKeepTarget.presetID(fromExerciseId: "timed.seed:maxhangs"))
        XCTAssertEqual(ProtocolKeepTarget.resolve(routineName: "Finger day", routineHasBlock: true, presetID: preset,
                                                  exerciseName: "Max hangs"),
                       .routine(routineName: "Finger day", exerciseName: "Max hangs"))
        XCTAssertEqual(ProtocolKeepTarget.resolve(routineName: "Finger day", routineHasBlock: false, presetID: preset,
                                                  exerciseName: "Max hangs"), .preset(name: "Max hangs"))
        XCTAssertEqual(ProtocolKeepTarget.resolve(routineName: nil, routineHasBlock: false, presetID: nil,
                                                  exerciseName: "Max hangs"), .session)
    }
}
