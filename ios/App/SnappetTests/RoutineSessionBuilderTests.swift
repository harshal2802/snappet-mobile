import XCTest
@testable import Snappet

/// The keystone bridge (workout-redesign E4): `RoutineSessionBuilder` maps a routine's discipline-aware
/// prescription to a live session's exercises, propagating the discipline + kind + per-axis metadata so a
/// routine-started session reconstructs the right card type (not always strength), and seeds a typed routine
/// block from a library item. All pure value mapping — no device.
final class RoutineSessionBuilderTests: XCTestCase {

    // MARK: - makeSession discipline propagation

    func testStrengthBlockStaysStrengthAndCarriesNoDisciplineRaw() {
        let re = RoutineExercise(exerciseId: "Bench_Press", sets: 3, reps: "8-12", restSeconds: 90, weight: 60)
        let se = RoutineSessionBuilder.sessionExercise(from: re, defaultUnit: .kg)
        XCTAssertEqual(se.discipline, .strength)
        XCTAssertNil(se.disciplineRaw, "a strength block keeps disciplineRaw nil (the additive-nil invariant)")
        XCTAssertNil(se.kindRaw, "strength keeps kindRaw nil → derives .repsWeight")
        XCTAssertEqual(se.kind, .repsWeight)
        XCTAssertEqual(se.sets.count, 3)
        XCTAssertTrue(se.sets.allSatisfy { $0.completedAt == nil }, "fresh sets are uncompleted")
        XCTAssertEqual(se.targetReps, "8-12")
        XCTAssertEqual(se.targetWeight, 60)
    }

    func testTimedBlockPropagatesDisciplineKindAndSpec() {
        var re = RoutineExercise(exerciseId: "timed.plank", sets: 3, reps: "30s", restSeconds: 45,
                                 displayName: "Plank", discipline: .timed,
                                 targetDurationSec: 30, timedCategory: TimedExerciseCategory.core.rawValue)
        re.timedSpec = TimedExerciseSpec.hold(30)
        let se = RoutineSessionBuilder.sessionExercise(from: re, defaultUnit: .kg)
        XCTAssertEqual(se.discipline, .timed)
        XCTAssertEqual(se.kind, .duration, "a timed block logs .duration sets, not reps×weight")
        XCTAssertEqual(se.disciplineRaw, WorkoutDiscipline.timed.rawValue)
        XCTAssertEqual(se.timedCategory, TimedExerciseCategory.core.rawValue)
        XCTAssertEqual(se.timedSpec?.workSec, 30)
        XCTAssertEqual(se.displayName, "Plank")
    }

    func testClimbBlockPropagatesGradePrescriptionAndStampsEachAttempt() {
        let re = RoutineExercise(exerciseId: "climb.project", sets: 4, reps: "", restSeconds: 240,
                                 displayName: "Project", discipline: .climb,
                                 climbTypeRaw: ClimbType.boulder.rawValue, climbGradeLabel: "V5",
                                 climbGradeScaleRaw: GradeScale.vScale.rawValue)
        let se = RoutineSessionBuilder.sessionExercise(from: re, defaultUnit: .kg)
        XCTAssertEqual(se.discipline, .climb)
        XCTAssertEqual(se.kind, .climbAttempt)
        XCTAssertEqual(se.climbType, .boulder)
        XCTAssertEqual(se.climbGradeLabel, "V5")
        XCTAssertEqual(se.climbGradeScale, .vScale)
        XCTAssertEqual(se.sets.count, 4, "4 attempts")
        XCTAssertTrue(se.sets.allSatisfy { $0.climbGradeLabel == "V5" },
                      "each fresh attempt is stamped with the prescribed grade so the pyramid reads")
        XCTAssertTrue(se.sets.allSatisfy { $0.completedAt == nil })
    }

    func testRunBlockLogsDurationKindNeverStrength() {
        let re = RoutineExercise(exerciseId: "run.easy", sets: 1, reps: "", restSeconds: 0,
                                 displayName: "Easy run", discipline: .run, targetDistanceMeters: 5000)
        let se = RoutineSessionBuilder.sessionExercise(from: re, defaultUnit: .kg)
        XCTAssertEqual(se.discipline, .run)
        XCTAssertEqual(se.kind, .duration, "a run never silently logs as strength reps×weight")
        XCTAssertEqual(se.disciplineRaw, WorkoutDiscipline.run.rawValue)
    }

    func testMixedRoutineReconstructsEachBlocksType() {
        let routine = Routine(name: "Mixed", exercises: [
            RoutineExercise(exerciseId: "Bench_Press", sets: 3, reps: "8", restSeconds: 90),
            RoutineExercise(exerciseId: "timed.plank", sets: 2, reps: "30s", restSeconds: 30,
                            displayName: "Plank", discipline: .timed, targetDurationSec: 30),
            RoutineExercise(exerciseId: "climb.boulder", sets: 3, reps: "", restSeconds: 120,
                            displayName: "Boulder", discipline: .climb, climbGradeLabel: "V3"),
            RoutineExercise(exerciseId: "run.easy", sets: 1, reps: "", restSeconds: 0,
                            displayName: "Run", discipline: .run, targetDistanceMeters: 5000),
        ])
        let ses = RoutineSessionBuilder.exercises(from: routine, defaultUnit: .kg)
        XCTAssertEqual(ses.map(\.discipline), [.strength, .timed, .climb, .run])
        XCTAssertEqual(ses.map(\.kind), [.repsWeight, .duration, .climbAttempt, .duration])
    }

    // MARK: - library item → routine block

    func testBlockFromStrengthLibraryItemUsesEditorDefaults() {
        let ex = Exercise(id: "Bench_Press", name: "Bench Press", force: .push, level: .intermediate,
                          mechanic: .compound, equipment: .barbell, primaryMuscles: [.chest],
                          secondaryMuscles: [], instructions: [], category: .strength)
        let item = LibraryItem(id: ex.id, title: ex.name, subtitle: "", discipline: .strength,
                               symbol: "dumbbell.fill", isCustom: false, source: .strength(ex))
        let block = RoutineSessionBuilder.block(from: item, defaultUnit: .lb,
                                                defaultSets: 4, defaultReps: "5", defaultRest: 120)
        XCTAssertEqual(block.discipline, .strength)
        XCTAssertEqual(block.exerciseId, "Bench_Press")
        XCTAssertEqual(block.sets, 4)
        XCTAssertEqual(block.reps, "5")
        XCTAssertEqual(block.restSeconds, 120)
        XCTAssertEqual(block.weightUnit, .lb)
    }

    func testBlockFromClimbStarterSeedsClimbPrescription() {
        let starter = ClimbStarter.all.first { $0.climbType == .boulder }!
        let item = LibraryItem(id: starter.key, title: starter.name, subtitle: "", discipline: .climb,
                               symbol: "figure.climbing", isCustom: false, source: .climb(starter))
        let block = RoutineSessionBuilder.block(from: item, defaultUnit: .kg)
        XCTAssertEqual(block.discipline, .climb)
        XCTAssertEqual(block.climbType, .boulder)
        XCTAssertEqual(block.climbGradeScale, .vScale)
        XCTAssertEqual(block.climbGradeLabel, GradeScale.vScale.defaultGrade)
        XCTAssertEqual(block.displayName, starter.name)
    }

    func testBlockFromRunStarterCarriesDistance() {
        let starter = RunStarter.all.first { $0.distanceMeters != nil }!
        let item = LibraryItem(id: starter.key, title: starter.name, subtitle: "", discipline: .run,
                               symbol: "figure.run", isCustom: false, source: .run(starter))
        let block = RoutineSessionBuilder.block(from: item, defaultUnit: .kg)
        XCTAssertEqual(block.discipline, .run)
        XCTAssertEqual(block.targetDistanceMeters, starter.distanceMeters)
    }

    func testBlockFromTimedLibraryItemCarriesSpecAndCategory() {
        let spec = TimedExerciseSpec.repeaters7x3x6
        let data = try? JSONEncoder().encode(spec)
        let item = LibraryItem(id: "timed.seed:repeaters", title: "Repeaters", subtitle: "",
                               discipline: .timed, symbol: "timer", isCustom: false,
                               source: .timed(specData: data, category: .hangboard, catalogID: nil))
        let block = RoutineSessionBuilder.block(from: item, defaultUnit: .kg)
        XCTAssertEqual(block.discipline, .timed)
        XCTAssertEqual(block.timedCategory, TimedExerciseCategory.hangboard.rawValue)
        XCTAssertEqual(block.timedSpec?.mode, .repeaters)
        XCTAssertEqual(block.sets, spec.sets, "a structured spec's set count seeds the block")
    }
}
