import XCTest
@testable import Snappet

/// Prompt 141 — "until I tap done" reps: the timeline blocks on each open rep until it's completed, the
/// clock carries on exactly after, and the new field never changes how older protocols decode.
final class SelfPacedRepTests: XCTestCase {

    private let contact = TimedExerciseSpec.contact   // 5 reps × 3 sets, 30 s rest, 180 s between sets, 5 s lead-in

    func testContactPresetMatchesTheRequest() {
        XCTAssertTrue(contact.isSelfPaced)
        XCTAssertEqual([contact.reps, contact.sets, contact.restSec, contact.restBetweenSetsSec], [5, 3, 30, 180])
        XCTAssertEqual(contact.sentence,
                       "3 sets × 5 reps, each until you tap done · 30 s between reps · 3 min between sets · about 12 min + your reps")
    }

    func testScheduleHasOneOpenPhasePerRepAndTotalCountsOnlyRests() {
        let s = IntervalSchedule(spec: contact)
        XCTAssertEqual(s.openRepCount, 15)
        // lead-in 5 + per set 4 × 30 rest + 2 × 180 between sets
        XCTAssertEqual(s.totalSeconds, 5 + 3 * 120 + 360)
        XCTAssertEqual(s.totalSeconds, contact.totalSeconds)
    }

    func testTheClockStopsAtAnOpenRepUntilItIsDone() {
        let s = IntervalSchedule(spec: contact)
        // During the lead-in.
        XCTAssertEqual(s.state(at: 2, completedOpenReps: 0).phase.kind, .leadIn)
        // At (or past) the end of the lead-in, rep 1 is active — however much time passes.
        let rep1 = s.state(at: 5, completedOpenReps: 0)
        XCTAssertTrue(rep1.phase.isOpenEnded)
        XCTAssertEqual(rep1.phase.label, "GO")
        XCTAssertEqual([rep1.setIndex, rep1.repIndex], [1, 1])
        XCTAssertEqual(rep1.startOfPhase, 5)
        XCTAssertTrue(s.state(at: 500, completedOpenReps: 0).phase.isOpenEnded, "never times out")
        // Rep 1 done → the 30 s rest runs from schedule time 5.
        let rest = s.state(at: 10, completedOpenReps: 1)
        XCTAssertEqual(rest.phase.kind, .rest)
        XCTAssertEqual(rest.remainingInPhase, 25)
        // Rest over → rep 2 blocks.
        let rep2 = s.state(at: 35, completedOpenReps: 1)
        XCTAssertTrue(rep2.phase.isOpenEnded)
        XCTAssertEqual(rep2.repIndex, 2)
    }

    func testBetweenSetRestFollowsTheLastRepOfASet() {
        let s = IntervalSchedule(spec: contact)
        // After 5 open reps (4 rests = 120 s after the 5 s lead-in), the 180 s between-set rest.
        let st = s.state(at: 125, completedOpenReps: 5)
        XCTAssertEqual(st.phase.kind, .restBetweenSets)
        XCTAssertEqual(st.remainingInPhase, 180)
    }

    func testDoneOnlyAfterEveryOpenRep() {
        let s = IntervalSchedule(spec: contact)
        XCTAssertFalse(s.state(at: Double(s.totalSeconds), completedOpenReps: 14).isDone, "last rep still open")
        XCTAssertTrue(s.state(at: Double(s.totalSeconds), completedOpenReps: 15).isDone)
    }

    func testTimedProtocolsAreUnchanged() {
        let s = IntervalSchedule(spec: .maxHangs)
        XCTAssertEqual(s.openRepCount, 0)
        XCTAssertEqual(s.state(at: 6).phase.kind, .work)
        XCTAssertTrue(s.state(at: Double(s.totalSeconds)).isDone)
    }

    // MARK: - Back-compat

    func testOlderProtocolsDecodeAsTimedWork() throws {
        let old = #"{"mode":"repeaters","workSec":7,"restSec":3,"reps":6,"sets":6,"restBetweenSetsSec":180,"leadInSec":3}"#
        let spec = try JSONDecoder().decode(TimedExerciseSpec.self, from: Data(old.utf8))
        XCTAssertFalse(spec.isSelfPaced)
        XCTAssertEqual(spec, .repeaters7x3x6)
    }

    func testTimedSpecsDoNotEncodeTheNewKey() throws {
        let json = String(decoding: try JSONEncoder().encode(TimedExerciseSpec.maxHangs), as: UTF8.self)
        XCTAssertFalse(json.contains("selfPacedWork"), "unchanged bytes for every existing protocol: \(json)")
        let contactJSON = String(decoding: try JSONEncoder().encode(contact), as: UTF8.self)
        XCTAssertTrue(contactJSON.contains("selfPacedWork"))
    }

    func testSelfPacedIsIgnoredForEmomAndHolds() {
        XCTAssertFalse(TimedExerciseSpec(mode: .emom, reps: 10, selfPacedWork: true).isSelfPaced)
        XCTAssertFalse(TimedExerciseSpec(mode: .countDown, workSec: 30, selfPacedWork: true).isSelfPaced)
    }

    func testEditorDraftRoundTripsSelfPaced() {
        var d = ProtocolDraft(spec: contact)
        XCTAssertTrue(d.selfPaced)
        XCTAssertEqual(d.spec, contact)
        d.selfPaced = false
        XCTAssertFalse(d.spec.isSelfPaced)
        XCTAssertGreaterThanOrEqual(d.spec.workSec, 1, "a timed rep always has a length")
    }
}
