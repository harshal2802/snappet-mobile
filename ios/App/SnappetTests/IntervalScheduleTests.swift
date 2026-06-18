import XCTest
@testable import Snappet

/// Unit tests for the **pure** `IntervalSchedule` (Quick Session redesign Phase 6) — no device, no
/// SwiftUI, no SwiftData. Exercises the timeline unroll (lead-in → work / rest / between-set rest → done),
/// the total-duration agreement with `TimedExerciseSpec.totalSeconds`, the phase boundaries, the set/rep
/// counter, the next-phase preview labels, and the edge cases (lead-in 0, single rep, EMOM 60 s windows).
final class IntervalScheduleTests: XCTestCase {

    // MARK: - Total duration agrees with the spec (structured modes)

    func testTabataTotalEqualsSpecTotal() {
        // 20:10 × 8, one set, 3 s lead-in → 233 s (matches TimedExerciseSpecTests).
        let sched = IntervalSchedule(spec: .tabata)
        XCTAssertEqual(sched.totalSeconds, 233)
        XCTAssertEqual(sched.totalSeconds, TimedExerciseSpec.tabata.totalSeconds)
    }

    func testRepeatersTotalEqualsSpecTotal() {
        // 7:3 × 6, six sets, 180 s between sets, 3 s lead-in → 1245 s.
        let sched = IntervalSchedule(spec: .repeaters7x3x6)
        XCTAssertEqual(sched.totalSeconds, 1245)
        XCTAssertEqual(sched.totalSeconds, TimedExerciseSpec.repeaters7x3x6.totalSeconds)
    }

    func testRepeaters7x3x6x3SetsTotal() {
        // The spec called out in the prompt: 7:3 × 6 × 3 sets, 180 s between sets, 3 s lead-in.
        // Per set: 6 work (42) + 5 inter-rep rests (15) = 57; three sets = 171; 2 between-set rests = 360;
        // + 3 lead-in = 534.
        let spec = TimedExerciseSpec(mode: .repeaters, workSec: 7, restSec: 3, reps: 6, sets: 3,
                                     restBetweenSetsSec: 180)
        let sched = IntervalSchedule(spec: spec)
        XCTAssertEqual(sched.totalSeconds, 534)
        XCTAssertEqual(sched.totalSeconds, spec.totalSeconds)
    }

    // MARK: - Phase composition

    func testTabataPhaseCounts() {
        // 8 work + 7 inter-rep rests + 1 lead-in + 1 done = 17 phases.
        let p = IntervalSchedule(spec: .tabata).phases
        XCTAssertEqual(p.count, 17)
        XCTAssertEqual(p.filter { $0.kind == .work }.count, 8)
        XCTAssertEqual(p.filter { $0.kind == .rest }.count, 7)
        XCTAssertEqual(p.filter { $0.kind == .leadIn }.count, 1)
        XCTAssertEqual(p.filter { $0.kind == .restBetweenSets }.count, 0)
        XCTAssertEqual(p.last?.kind, .done)
    }

    func testRepeatersBetweenSetRestCount() {
        // 7:3 × 6 × 6 sets: per set 6 work + 5 rests = 11; × 6 = 66; + 5 between-set rests + lead-in + done.
        let p = IntervalSchedule(spec: .repeaters7x3x6).phases
        XCTAssertEqual(p.filter { $0.kind == .work }.count, 36)
        XCTAssertEqual(p.filter { $0.kind == .rest }.count, 30)        // 5 per set × 6 sets
        XCTAssertEqual(p.filter { $0.kind == .restBetweenSets }.count, 5)  // between 6 sets
    }

    func testNoTrailingRestAfterLastRep() {
        // The phase before `.done` is always a work phase (no rest hanging off the end).
        let p = IntervalSchedule(spec: .tabata).phases
        XCTAssertEqual(p.last?.kind, .done)
        XCTAssertEqual(p[p.count - 2].kind, .work)
    }

    // MARK: - Lead-in

    func testLeadInIsFirstAndCarriesItsDuration() {
        let p = IntervalSchedule(spec: .tabata).phases
        XCTAssertEqual(p.first?.kind, .leadIn)
        XCTAssertEqual(p.first?.durationSec, 3)
        XCTAssertEqual(p.first?.label, "READY")
    }

    func testLeadInZeroProducesNoLeadInPhase() {
        let spec = TimedExerciseSpec(mode: .tabata, workSec: 20, restSec: 10, reps: 8, sets: 1, leadInSec: 0)
        let p = IntervalSchedule(spec: spec).phases
        XCTAssertEqual(p.filter { $0.kind == .leadIn }.count, 0)
        XCTAssertEqual(p.first?.kind, .work)
        XCTAssertEqual(IntervalSchedule(spec: spec).totalSeconds, 230)
    }

    // MARK: - State at elapsed (boundaries)

    func testStateDuringLeadIn() {
        let s = IntervalSchedule(spec: .tabata)
        let st = s.state(at: 0)
        XCTAssertEqual(st.phase.kind, .leadIn)
        XCTAssertEqual(st.remainingInPhase, 3)
        XCTAssertFalse(st.isDone)
        // Lead-in does not show a rep.
        XCTAssertEqual(st.repIndex, 0)
    }

    func testStateAtFirstWorkBoundary() {
        let s = IntervalSchedule(spec: .tabata) // 3 lead-in, then 20 s work.
        // Just inside the first work phase.
        let st = s.state(at: 3.0)
        XCTAssertEqual(st.phase.kind, .work)
        XCTAssertEqual(st.setIndex, 1)
        XCTAssertEqual(st.repIndex, 1)
        XCTAssertEqual(st.remainingInPhase, 20)
    }

    func testStateInFirstRestPhase() {
        let s = IntervalSchedule(spec: .tabata) // lead-in 3, work 20 → rest starts at 23.
        let st = s.state(at: 23.5)
        XCTAssertEqual(st.phase.kind, .rest)
        XCTAssertEqual(st.repIndex, 1, "the rest belongs to the rep just worked")
        XCTAssertEqual(st.remainingInPhase, 10)
    }

    func testStateInSecondWork() {
        // lead-in 3 + work 20 + rest 10 = 33 → second work rep starts.
        let s = IntervalSchedule(spec: .tabata)
        let st = s.state(at: 33.0)
        XCTAssertEqual(st.phase.kind, .work)
        XCTAssertEqual(st.repIndex, 2)
    }

    func testStateAtAndPastEndIsDone() {
        let s = IntervalSchedule(spec: .tabata)
        let total = Double(s.totalSeconds)
        let atEnd = s.state(at: total)
        XCTAssertTrue(atEnd.isDone)
        XCTAssertEqual(atEnd.phase.kind, .done)
        XCTAssertEqual(atEnd.remainingInPhase, 0)
        XCTAssertEqual(atEnd.overallRemaining, 0)

        let past = s.state(at: total + 100)
        XCTAssertTrue(past.isDone)
    }

    func testOverallRemainingDrainsToZero() {
        let s = IntervalSchedule(spec: .tabata)
        XCTAssertEqual(s.state(at: 0).overallRemaining, s.totalSeconds)
        // Halfway-ish: overall remaining is monotonically non-increasing.
        let a = s.state(at: 50).overallRemaining
        let b = s.state(at: 100).overallRemaining
        XCTAssertGreaterThan(a, b)
    }

    // MARK: - Multi-set set/rep counter

    func testSetIndexAdvancesAcrossSets() {
        // 7:3 × 2 reps × 2 sets, 5 s between, lead-in 0.
        // set1: work(0-7) rest(7-10) work(10-17) between(17-22) | set2: work(22-29) rest(29-32) work(32-39)
        let spec = TimedExerciseSpec(mode: .repeaters, workSec: 7, restSec: 3, reps: 2, sets: 2,
                                     restBetweenSetsSec: 5, leadInSec: 0)
        let s = IntervalSchedule(spec: spec)
        XCTAssertEqual(s.state(at: 0).setIndex, 1)
        XCTAssertEqual(s.state(at: 0).repIndex, 1)
        XCTAssertEqual(s.state(at: 11).setIndex, 1)
        XCTAssertEqual(s.state(at: 11).repIndex, 2)
        // Between-set rest at 17-22: shows the set just finished, no rep.
        let between = s.state(at: 18)
        XCTAssertEqual(between.phase.kind, .restBetweenSets)
        XCTAssertEqual(between.repIndex, 0)
        // Second set's first work.
        let set2 = s.state(at: 23)
        XCTAssertEqual(set2.setIndex, 2)
        XCTAssertEqual(set2.repIndex, 1)
        // Total: per set 7+3+7=17; ×2 = 34; +1 between = 39.
        XCTAssertEqual(s.totalSeconds, 39)
        XCTAssertEqual(s.totalSeconds, spec.totalSeconds)
    }

    // MARK: - EMOM (60 s windows)

    func testEmomBuildsSixtySecondWorkWindows() {
        // EMOM × 10, default 3 s lead-in. Each rep is a 60 s work window, no rest.
        let s = IntervalSchedule(spec: .emom)
        XCTAssertEqual(s.phases.filter { $0.kind == .work }.count, 10)
        XCTAssertEqual(s.phases.filter { $0.kind == .rest }.count, 0)
        XCTAssertEqual(s.phases.first { $0.kind == .work }?.durationSec, 60)
        // Total = lead-in 3 + 10 × 60 = 603.
        XCTAssertEqual(s.totalSeconds, 603)
        // Mid-window read.
        let st = s.state(at: 3 + 90) // into the 2nd minute.
        XCTAssertEqual(st.phase.kind, .work)
        XCTAssertEqual(st.repIndex, 2)
    }

    // MARK: - Edge: single rep / single set

    func testSingleRepSingleSetIsJustLeadInPlusWork() {
        let spec = TimedExerciseSpec(mode: .repeaters, workSec: 10, restSec: 5, reps: 1, sets: 1, leadInSec: 3)
        let s = IntervalSchedule(spec: spec)
        // lead-in + one work + done (no rest at all — only one rep, one set).
        XCTAssertEqual(s.phases.map(\.kind), [.leadIn, .work, .done])
        XCTAssertEqual(s.totalSeconds, 13)
    }

    // MARK: - Next-phase preview labels

    func testNextLabelTelegraphsTheFollowingPhase() {
        let p = IntervalSchedule(spec: .tabata).phases
        // Lead-in's next is the first WORK.
        XCTAssertEqual(p.first?.nextLabel, "WORK")
        // A work phase that is followed by a rest previews REST.
        let firstWork = p.first { $0.kind == .work }
        XCTAssertEqual(firstWork?.nextLabel, "REST")
        // The very last work (before done) has no next.
        XCTAssertNil(p[p.count - 2].nextLabel)
    }
}
