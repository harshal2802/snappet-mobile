import XCTest
@testable import Snappet

/// Migration-safety of the keystone change (workout-redesign E4): `RoutineExercise` gained
/// `disciplineRaw` + per-axis target Optionals + climb/timed prescription. Because `RoutineExercise` is a
/// nested `Codable` composite (inside `Routine.exercises` / `RoutineRow`) — NOT an `@Model` — SwiftData
/// lightweight migration doesn't reach inside the blob; the safety rests entirely on synthesized `Codable`:
/// a missing optional key decodes as `nil`, and a nil optional is OMITTED on encode (so backup golden bytes
/// stay stable). These tests pin both halves of that invariant so the keystone can't silently break a
/// pre-E4 routine or shift the `SnappetBackup` bytes.
final class RoutineExerciseMigrationTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()

    // MARK: - Legacy blob decodes (no discipline fields)

    /// A pre-E4 `RoutineExercise` JSON (only the original keys) decodes with `discipline == .strength` and
    /// every new target nil — proving the additive fields don't break old stored routines.
    func testLegacyRoutineExerciseBlobDecodesAsStrengthWithNilTargets() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","exerciseId":"Bench_Press",
         "sets":3,"reps":"8-12","restSeconds":90,"weight":60,"weightUnit":"kg",
         "notes":"pause reps","displayName":"Bench"}
        """
        let re = try JSONDecoder().decode(RoutineExercise.self, from: Data(legacy.utf8))
        XCTAssertEqual(re.exerciseId, "Bench_Press")
        XCTAssertEqual(re.sets, 3)
        XCTAssertEqual(re.reps, "8-12")
        XCTAssertEqual(re.weight, 60)
        // The keystone fields default safely.
        XCTAssertNil(re.disciplineRaw)
        XCTAssertEqual(re.discipline, .strength, "a legacy routine exercise derives .strength")
        XCTAssertNil(re.targetDurationSec)
        XCTAssertNil(re.targetDistanceMeters)
        XCTAssertNil(re.targetRPE)
        XCTAssertNil(re.climbTypeRaw)
        XCTAssertNil(re.climbGradeLabel)
        XCTAssertNil(re.timedSpecData)
        XCTAssertNil(re.timedCategory)
        XCTAssertEqual(re.climbType, .boulder, "climb defaults apply even on a strength block")
    }

    /// A pre-E4 whole `Routine` JSON (its `exercises` array carries only the original keys) decodes too —
    /// the array element is the same composite, so a stored starter routine survives the change.
    func testLegacyRoutineRowBlobDecodes() throws {
        let legacy = """
        {"id":"22222222-2222-2222-2222-222222222222","name":"Push day",
         "exercises":[{"id":"33333333-3333-3333-3333-333333333333","exerciseId":"Pushups",
                       "sets":4,"reps":"8-12","restSeconds":90}],
         "createdAt":0,"updatedAt":0,"isStarter":true,"starterKey":"starter-x","tags":[]}
        """
        let row = try JSONDecoder().decode(SnappetBackup.RoutineRow.self, from: Data(legacy.utf8))
        XCTAssertEqual(row.name, "Push day")
        XCTAssertEqual(row.exercises.count, 1)
        XCTAssertEqual(row.exercises[0].discipline, .strength)
        XCTAssertNil(row.exercises[0].disciplineRaw)
    }

    // MARK: - Byte stability (the additive-nil invariant — backup golden bytes can't shift)

    /// A strength `RoutineExercise` (no discipline / no targets set) encodes to the SAME bytes as a struct
    /// built from only the original fields — i.e. the new optional keys are OMITTED, not emitted as null.
    /// This is exactly why `SnappetBackupTests`' golden round-trip stays stable.
    func testStrengthBlockEncodesWithoutNewKeys() throws {
        let re = RoutineExercise(exerciseId: "Bench_Press", sets: 3, reps: "8-12", restSeconds: 90,
                                 weight: 60, weightUnit: .kg, notes: "pause reps", displayName: "Bench")
        let json = String(data: try encoder.encode(re), encoding: .utf8)!
        for absent in ["disciplineRaw", "targetDurationSec", "targetDistanceMeters", "targetRPE",
                       "climbTypeRaw", "climbGradeLabel", "climbGradeScaleRaw", "timedSpecData", "timedCategory"] {
            XCTAssertFalse(json.contains(absent),
                           "a nil optional must be OMITTED on encode (\(absent) leaked → bytes would shift)")
        }
        // Sanity: the original keys are all present.
        for present in ["exerciseId", "sets", "reps", "restSeconds", "weight", "weightUnit", "notes", "displayName"] {
            XCTAssertTrue(json.contains("\"\(present)\""))
        }
    }

    /// A non-strength block DOES emit its set keys (so it round-trips), and decoding them back is lossless.
    func testTimedAndClimbBlocksRoundTripTheirNewFields() throws {
        var timed = RoutineExercise(exerciseId: "timed.plank", sets: 3, reps: "", restSeconds: 45,
                                    displayName: "Plank", discipline: .timed,
                                    targetDurationSec: 45, timedCategory: TimedExerciseCategory.core.rawValue)
        timed.timedSpec = .hold(45)
        let timedBack = try JSONDecoder().decode(RoutineExercise.self, from: try encoder.encode(timed))
        XCTAssertEqual(timedBack, timed)
        XCTAssertEqual(timedBack.discipline, .timed)
        XCTAssertEqual(timedBack.timedSpec?.workSec, 45)

        let climb = RoutineExercise(exerciseId: "climb.x", sets: 4, reps: "", restSeconds: 180,
                                    displayName: "Project", discipline: .climb,
                                    climbTypeRaw: ClimbType.boulder.rawValue, climbGradeLabel: "V5",
                                    climbGradeScaleRaw: GradeScale.vScale.rawValue)
        let climbBack = try JSONDecoder().decode(RoutineExercise.self, from: try encoder.encode(climb))
        XCTAssertEqual(climbBack, climb)
        XCTAssertEqual(climbBack.climbGradeLabel, "V5")
    }

    /// The starter re-author (E4) produces real discipline-tagged blocks — the climb starters now prescribe
    /// climbing and the timed holds are `.timed` blocks, not faked reps strings.
    func testStarterRoutinesCarryRealDisciplines() {
        let pyramid = StarterRoutines.all.first { $0.key == "starter-bouldering-pyramid" }
        XCTAssertNotNil(pyramid)
        let climbBlocks = pyramid!.blocks.map { $0.routineExercise }
        XCTAssertTrue(climbBlocks.allSatisfy { $0.discipline == .climb }, "the boulder pyramid is all climb blocks")
        XCTAssertTrue(climbBlocks.allSatisfy { ($0.climbGradeLabel ?? "").isEmpty == false })

        // A timed hold in the mobility starter is a .timed block, not "60s" faked into reps.
        let mobility = StarterRoutines.all.first { $0.key == "starter-mobility" }!.blocks.map { $0.routineExercise }
        XCTAssertTrue(mobility.allSatisfy { $0.discipline == .timed })
        XCTAssertTrue(mobility.allSatisfy { ($0.targetDurationSec ?? 0) > 0 })
    }
}
