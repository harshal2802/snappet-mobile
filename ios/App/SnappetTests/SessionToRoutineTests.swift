import XCTest
@testable import Snappet

/// The pure actuals→prescription converter (workout-redesign E5): `SessionToRoutine` maps a finished
/// session's logged actuals back to a routine's per-discipline prescription — the *inverse* of
/// `RoutineSessionBuilder` — so a Quick Session can be saved as a repeatable, discipline-preserving routine.
/// Lossy by design, so these tests pin the per-discipline rules + the freeform → routine → freeform
/// round-trip that proves discipline survives. All pure value mapping — no device.
final class SessionToRoutineTests: XCTestCase {

    // MARK: - Builders (mirror FreeformSummaryTests)

    private func lift(_ reps: Int?, _ weight: Double?, unit: WeightUnit = .kg, done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil)
    }
    private func climb(_ grade: String?, _ status: KilterAscentStatus, done: Bool = true) -> SetLog {
        SetLog(completedAt: done ? Date(timeIntervalSince1970: 0) : nil,
               climbGradeLabel: grade, climbStatusRaw: status.rawValue)
    }
    private func timed(_ sec: Double, done: Bool = true) -> SetLog {
        SetLog(completedAt: done ? Date(timeIntervalSince1970: 0) : nil, durationSec: sec)
    }
    private func run(_ meters: Double, sec: Double, done: Bool = true) -> SetLog {
        var s = SetLog(completedAt: done ? Date(timeIntervalSince1970: 0) : nil, durationSec: sec)
        s.distanceMeters = meters
        return s
    }
    private func strengthEx(_ id: String, _ sets: [SetLog], name: String? = nil) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: sets, displayName: name, kindRaw: SetKind.repsWeight.rawValue)
    }
    private func session(_ exercises: [SessionExercise], name: String = "Quick session") -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 0)
        return WorkoutSession(routineID: nil, routineName: name, startedAt: start,
                              completedAt: start.addingTimeInterval(1800), exercises: exercises)
    }

    // MARK: - Strength rule

    func testStrengthBlockUsesCompletedSetCountModalRepsAndTopWeight() {
        // 3 completed sets: 8×60, 8×60, 5×70 → mode reps = 8; top weighted set = 5×70 (350 > 480? no:
        // 8×60 = 480 kg·reps vs 5×70 = 350 → top is 8×60 @ 60). Plus one UNcompleted set (ignored).
        let ex = strengthEx("Bench_Press", [lift(8, 60), lift(8, 60), lift(5, 70), lift(10, 80, done: false)],
                            name: "Bench")
        let blocks = SessionToRoutine.routineExercises(from: session([ex]), defaultUnit: .kg)
        XCTAssertEqual(blocks.count, 1)
        let b = blocks[0]
        XCTAssertEqual(b.discipline, .strength)
        XCTAssertNil(b.disciplineRaw, "a strength block keeps disciplineRaw nil (the additive-nil invariant)")
        XCTAssertEqual(b.exerciseId, "Bench_Press")
        XCTAssertEqual(b.sets, 3, "only the 3 COMPLETED sets are prescribed")
        XCTAssertEqual(b.reps, "8", "the modal completed reps")
        XCTAssertEqual(b.weight, 60, "the heaviest WORKING (weight×reps) set's weight, in its own unit")
        XCTAssertEqual(b.weightUnit, .kg)
        XCTAssertEqual(b.displayName, "Bench")
    }

    func testStrengthTopWeightRanksByWeightTimesRepsNotRawWeight() {
        // 10×100 (1000) beats 3×120 (360) even though 120 is heavier → prescribe 100.
        let ex = strengthEx("Squat", [lift(10, 100), lift(3, 120)])
        let b = SessionToRoutine.routineExercise(from: ex, defaultUnit: .kg)
        XCTAssertEqual(b?.weight, 100)
    }

    func testBodyweightStrengthBlockHasNoWeightButKeepsReps() {
        let ex = strengthEx("Pull_Up", [lift(12, nil), lift(10, nil), lift(10, nil)])
        let b = SessionToRoutine.routineExercise(from: ex, defaultUnit: .kg)
        XCTAssertNil(b?.weight, "a bodyweight block prescribes no starting weight")
        XCTAssertEqual(b?.reps, "10", "modal reps (10 appears twice)")
        XCTAssertEqual(b?.sets, 3)
    }

    func testRepresentativeRepsResolvesTiesToHigherReps() {
        // 8 and 10 each appear once (a tie) → the higher reps wins.
        XCTAssertEqual(SessionToRoutine.representativeReps([lift(8, 60), lift(10, 60)]), "10")
    }

    // MARK: - Climb rule

    func testClimbBlockCarriesTypeGradeScaleAndAttemptCount() {
        var c = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [climb("V5", .attempt), climb("V5", .sent)],
                                displayName: "Cave", kindRaw: SetKind.climbAttempt.rawValue)
        c.climbTypeRaw = ClimbType.boulder.rawValue
        c.climbGradeLabel = "V5"
        c.climbGradeScaleRaw = GradeScale.vScale.rawValue
        let b = SessionToRoutine.routineExercise(from: c, defaultUnit: .kg)
        XCTAssertEqual(b?.discipline, .climb)
        XCTAssertEqual(b?.climbType, .boulder)
        XCTAssertEqual(b?.climbGradeLabel, "V5", "the climb's grade IS the routine slot")
        XCTAssertEqual(b?.climbGradeScale, .vScale)
        XCTAssertEqual(b?.sets, 2, "the number of logged attempts")
        XCTAssertEqual(b?.disciplineRaw, WorkoutDiscipline.climb.rawValue)
    }

    func testRoutedClimbBlockKeepsItsScale() {
        var c = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [climb("5.11a", .sent)],
                                kindRaw: SetKind.climbAttempt.rawValue)
        c.climbTypeRaw = ClimbType.lead.rawValue
        c.climbGradeLabel = "5.11a"
        c.climbGradeScaleRaw = GradeScale.yds.rawValue
        let b = SessionToRoutine.routineExercise(from: c, defaultUnit: .kg)
        XCTAssertEqual(b?.climbType, .lead)
        XCTAssertEqual(b?.climbGradeScale, .yds)
        XCTAssertEqual(b?.climbGradeLabel, "5.11a")
    }

    // MARK: - Timed rule

    func testTimedSimpleHoldUsesMedianDurationAndCompletedSetCount() {
        var t = SessionExercise(exerciseId: "timed.plank", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [timed(30), timed(45), timed(40)],
                                displayName: "Plank", kindRaw: SetKind.duration.rawValue)
        t.disciplineRaw = WorkoutDiscipline.timed.rawValue
        t.timedSpec = TimedExerciseSpec.hold(30)
        t.timedCategory = TimedExerciseCategory.core.rawValue
        let b = SessionToRoutine.routineExercise(from: t, defaultUnit: .kg)
        XCTAssertEqual(b?.discipline, .timed)
        XCTAssertEqual(b?.sets, 3)
        XCTAssertEqual(b?.targetDurationSec, 40, "median of [30,40,45]")
        XCTAssertEqual(b?.timedCategory, TimedExerciseCategory.core.rawValue)
        XCTAssertNotNil(b?.timedSpecData, "the spec is carried through verbatim")
    }

    func testTimedStructuredProtocolKeepsItsSpecSetCountAndNoSeparateTarget() {
        let spec = TimedExerciseSpec.repeaters7x3x6   // a structured (repeaters) spec carrying its own sets
        var t = SessionExercise(exerciseId: "timed.repeaters", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [timed(120), timed(120)],
                                displayName: "Repeaters", kindRaw: SetKind.duration.rawValue)
        t.disciplineRaw = WorkoutDiscipline.timed.rawValue
        t.timedSpec = spec
        let b = SessionToRoutine.routineExercise(from: t, defaultUnit: .kg)
        XCTAssertEqual(b?.sets, spec.sets, "a structured spec's set count drives the block, not the log count")
        XCTAssertNil(b?.targetDurationSec, "a structured spec already carries its work seconds — no double target")
        XCTAssertEqual(b?.timedSpec?.mode, .repeaters)
    }

    // MARK: - Run rule

    func testRunBlockTargetsTotalDistanceAndNeverDegradesToStrength() {
        var r = SessionExercise(exerciseId: "adhoc-run", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [run(3000, sec: 900), run(2000, sec: 600)],
                                displayName: "Run", kindRaw: SetKind.duration.rawValue)
        r.disciplineRaw = WorkoutDiscipline.run.rawValue
        let b = SessionToRoutine.routineExercise(from: r, defaultUnit: .kg)
        XCTAssertEqual(b?.discipline, .run)
        XCTAssertEqual(b?.sets, 1, "a run is a single block")
        XCTAssertEqual(b?.targetDistanceMeters, 5000, "Σ completed distance")
        XCTAssertNil(b?.weight, "a run never silently carries a strength weight")
    }

    // MARK: - Dropping empty exercises

    func testExerciseWithNoCompletedSetIsDropped() {
        let warmup = strengthEx("Warmup", [lift(10, 20, done: false)])   // logged nothing completed
        let working = strengthEx("Bench_Press", [lift(8, 60)])
        let blocks = SessionToRoutine.routineExercises(from: session([warmup, working]), defaultUnit: .kg)
        XCTAssertEqual(blocks.map(\.exerciseId), ["Bench_Press"], "an exercise with no completed set is dropped")
    }

    func testEmptyExerciseConvertsToNil() {
        XCTAssertNil(SessionToRoutine.routineExercise(from: strengthEx("x", []), defaultUnit: .kg))
    }

    // MARK: - Mixed session preserves every discipline

    func testMixedSessionConvertsEachBlockToItsOwnDiscipline() {
        var c = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [climb("V3", .sent)],
                                kindRaw: SetKind.climbAttempt.rawValue)
        c.climbTypeRaw = ClimbType.boulder.rawValue; c.climbGradeLabel = "V3"
        var t = SessionExercise(exerciseId: "timed.plank", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [timed(30)], kindRaw: SetKind.duration.rawValue)
        t.disciplineRaw = WorkoutDiscipline.timed.rawValue
        var r = SessionExercise(exerciseId: "adhoc-run", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [run(5000, sec: 1500)],
                                kindRaw: SetKind.duration.rawValue)
        r.disciplineRaw = WorkoutDiscipline.run.rawValue
        let blocks = SessionToRoutine.routineExercises(
            from: session([strengthEx("Bench_Press", [lift(8, 60)]), c, t, r]), defaultUnit: .kg)
        XCTAssertEqual(blocks.map(\.discipline), [.strength, .climb, .timed, .run])
    }

    // MARK: - Round-trip: freeform → routine → freeform preserves discipline (the E4 inverse)

    func testRoundTripThroughBuilderPreservesDiscipline() {
        var c = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [climb("V4", .sent), climb("V4", .attempt)],
                                kindRaw: SetKind.climbAttempt.rawValue)
        c.climbTypeRaw = ClimbType.boulder.rawValue; c.climbGradeLabel = "V4"
        c.climbGradeScaleRaw = GradeScale.vScale.rawValue
        var t = SessionExercise(exerciseId: "timed.plank", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [timed(40), timed(50)],
                                kindRaw: SetKind.duration.rawValue)
        t.disciplineRaw = WorkoutDiscipline.timed.rawValue; t.timedSpec = .hold(40)
        let original = session([strengthEx("Bench_Press", [lift(8, 60)]), c, t])

        // session → routine prescription (E5 converter)
        let blocks = SessionToRoutine.routineExercises(from: original, defaultUnit: .kg)
        let routine = Routine(name: "Saved", exercises: blocks)
        // routine → session (E4 builder, the forward map)
        let rebuilt = RoutineSessionBuilder.exercises(from: routine, defaultUnit: .kg)

        XCTAssertEqual(rebuilt.map(\.discipline), [.strength, .climb, .timed],
                       "discipline survives the freeform → routine → freeform round-trip")
        XCTAssertEqual(rebuilt.map(\.kind), [.repsWeight, .climbAttempt, .duration])
        // The climb's grade prescription survives + each rebuilt attempt is re-stamped with it.
        let rebuiltClimb = rebuilt[1]
        XCTAssertEqual(rebuiltClimb.climbGradeLabel, "V4")
        XCTAssertTrue(rebuiltClimb.sets.allSatisfy { $0.climbGradeLabel == "V4" })
        // The timed block's spec survives.
        XCTAssertEqual(rebuilt[2].timedSpec?.workSec, 40)
    }

    // MARK: - Name + sport suggestion

    func testSuggestedNameUsesNonGenericSessionName() {
        XCTAssertEqual(SessionToRoutine.suggestedName(for: session([strengthEx("x", [lift(8, 60)])],
                                                                    name: "Wednesday Push")),
                       "Wednesday Push")
    }

    func testSuggestedNameFallsBackToDisciplineLabelForGenericSession() {
        var c = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [climb("V3", .sent)],
                                kindRaw: SetKind.climbAttempt.rawValue)
        c.climbGradeLabel = "V3"
        XCTAssertEqual(SessionToRoutine.suggestedName(for: session([c], name: "Quick session")),
                       "Climbing session")
        XCTAssertEqual(SessionToRoutine.suggestedName(for: session([strengthEx("x", [lift(8, 60)])],
                                                                    name: "Quick session")),
                       "Strength session")
    }

    func testDraftInfersClimbingSportAndConvertsBlocks() {
        var c = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                targetRestSeconds: 0, sets: [climb("V2", .sent)],
                                kindRaw: SetKind.climbAttempt.rawValue)
        c.climbGradeLabel = "V2"
        let draft = SessionToRoutine.draft(from: session([c]), defaultUnit: .kg)
        XCTAssertEqual(draft.sport, .climbing)
        XCTAssertEqual(draft.exercises.count, 1)
        XCTAssertEqual(draft.exercises[0].discipline, .climb)
    }

    func testCanConvertGatesOnACompletedSet() {
        XCTAssertFalse(SessionToRoutine.canConvert(session([strengthEx("x", [lift(8, 60, done: false)])])))
        XCTAssertTrue(SessionToRoutine.canConvert(session([strengthEx("x", [lift(8, 60)])])))
    }
}
