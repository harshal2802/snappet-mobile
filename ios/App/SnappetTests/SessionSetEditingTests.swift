import XCTest
import SwiftData
@testable import Snappet

/// Unit tests for the **pure** `SessionSetEditing` draft build/apply (issue #73), plus an in-memory
/// SwiftData round-trip locking the downstream guarantee: a corrected set changes what
/// `WorkoutMath` (PRs / volume) computes from the *stored* values.
@MainActor
final class SessionSetEditingTests: XCTestCase {

    /// Kept as a property: a `ModelContext` does NOT retain its `ModelContainer`, so a helper
    /// returning only the context lets the container deallocate and every later SwiftData call
    /// traps (EXC_BREAKPOINT, no message). Hold the container for the test's lifetime.
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    // MARK: - Builders

    private func set(_ reps: Int?, _ weight: Double?, unit: WeightUnit? = .kg,
                     done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil)
    }

    private func exercise(_ id: String, _ sets: [SetLog], kind: SetKind? = nil,
                          skipped: Bool = false) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: sets.count, targetReps: "",
                        targetRestSeconds: 0, sets: sets, skipped: skipped,
                        kindRaw: kind?.rawValue)
    }

    private func key(_ ex: SessionExercise, _ i: Int) -> SessionSetEditing.Key {
        SessionSetEditing.Key(exerciseID: ex.id, setIndex: i)
    }

    // MARK: - Draft building

    func testDraftsCoverCompletedSetsOfEveryDisciplineIncludingSkippedExercises() {
        let bench = exercise("bench", [set(8, 60), set(nil, nil, done: false)])
        let plank = exercise("plank", [SetLog(completedAt: .now, durationSec: 60)], kind: .duration)
        // Skipped mid-exercise: the completed set counts in WorkoutMath's volume/PRs, so it must
        // stay draftable (visible + fixable); the never-completed set has nothing to edit.
        let skipped = exercise("row", [set(10, 40), set(nil, nil, done: false)], skipped: true)
        let drafts = SessionSetEditing.drafts(for: [bench, plank, skipped], unit: .kg)

        // All-axis: the timed plank's completed set is now draftable too (was reps/weight-only before).
        XCTAssertEqual(drafts.count, 3, "bench set 1 + the plank's timed set + the skipped exercise's set")
        XCTAssertEqual(drafts[key(bench, 0)], SessionSetEditing.Draft(reps: "8", weight: "60"))
        XCTAssertEqual(drafts[key(plank, 0)], SessionSetEditing.Draft(duration: "1:00"))
        XCTAssertEqual(drafts[key(skipped, 0)], SessionSetEditing.Draft(reps: "10", weight: "40"))
        XCTAssertNil(drafts[key(skipped, 1)], "never-completed sets aren't draftable")
    }

    // MARK: - All-axis (timed / running / climbing) round-trips

    private func entity(_ id: String, _ discipline: WorkoutDiscipline, _ sets: [SetLog]) -> SessionExercise {
        var e = SessionExercise(exerciseId: id, targetSets: sets.count, targetReps: "", targetRestSeconds: 0,
                                sets: sets, kindRaw: discipline.defaultSetKind.rawValue)
        e.disciplineRaw = discipline.rawValue
        return e
    }

    func testTimedDurationEditRoundTrips() {
        let plank = entity("plank", .timed, [SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 60)])
        var drafts = SessionSetEditing.drafts(for: [plank], unit: .kg)
        XCTAssertEqual(drafts[key(plank, 0)], SessionSetEditing.Draft(duration: "1:00"))
        drafts[key(plank, 0)]?.duration = "1:30"
        let fixed = SessionSetEditing.apply(drafts: drafts, to: [plank], unit: .kg)
        XCTAssertEqual(fixed[0].sets[0].durationSec, 90)
        XCTAssertEqual(fixed[0].sets[0].actualWeight, nil, "a timed edit never writes reps/weight")
    }

    func testRunDistanceAndDurationEditRoundTrips() {
        var leg = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 1500)
        leg.distanceMeters = 5000
        let run = entity("run", .run, [leg])
        var drafts = SessionSetEditing.drafts(for: [run], unit: .kg)   // km (kg→km)
        XCTAssertEqual(drafts[key(run, 0)], SessionSetEditing.Draft(duration: "25:00", distance: "5"))
        drafts[key(run, 0)] = SessionSetEditing.Draft(duration: "24:00", distance: "5.2")
        let fixed = SessionSetEditing.apply(drafts: drafts, to: [run], unit: .kg)
        XCTAssertEqual(fixed[0].sets[0].distanceMeters ?? 0, 5200, accuracy: 0.001)
        XCTAssertEqual(fixed[0].sets[0].durationSec, 1440)
    }

    func testRunDistanceSeedsInMilesWhenLbPreferred() {
        var leg = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 600)
        leg.distanceMeters = 1609.344   // exactly 1 mi
        let run = entity("run", .run, [leg])
        let drafts = SessionSetEditing.drafts(for: [run], unit: .lb)
        XCTAssertEqual(drafts[key(run, 0)]?.distance, "1")
    }

    func testClimbGradeStatusAttemptsEditRoundTrips() {
        let climb = entity("climb", .climb, [SetLog(completedAt: Date(timeIntervalSince1970: 0),
                                                    climbGradeLabel: "V4",
                                                    climbStatusRaw: KilterAscentStatus.project.rawValue,
                                                    climbAttempts: 3)])
        var drafts = SessionSetEditing.drafts(for: [climb], unit: .kg)
        XCTAssertEqual(drafts[key(climb, 0)],
                       SessionSetEditing.Draft(grade: "V4", statusRaw: "project", attempts: "3"))
        // Correct it to a flashed V5 in one try.
        drafts[key(climb, 0)] = SessionSetEditing.Draft(grade: "V5", statusRaw: KilterAscentStatus.flash.rawValue, attempts: "1")
        let fixed = SessionSetEditing.apply(drafts: drafts, to: [climb], unit: .kg)
        XCTAssertEqual(fixed[0].sets[0].climbGradeLabel, "V5")
        XCTAssertEqual(fixed[0].sets[0].climbStatusRaw, "flash")
        XCTAssertEqual(fixed[0].sets[0].climbAttempts, 1)
    }

    func testUntouchedNonStrengthDraftsAreIdentity() {
        var leg = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 1500); leg.distanceMeters = 5000
        let run = entity("run", .run, [leg])
        let timed = entity("plank", .timed, [SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: 45)])
        let drafts = SessionSetEditing.drafts(for: [run, timed], unit: .kg)
        XCTAssertEqual(SessionSetEditing.apply(drafts: drafts, to: [run, timed], unit: .kg), [run, timed],
                       "saving without edits round-trips bit-identically across disciplines")
    }

    func testDraftTextFormatsLikeThePlayer() {
        // 62.5 keeps its decimal, nil fields become empty text (the player's blank state).
        let ex = exercise("ohp", [set(5, 62.5), set(12, nil)])
        let drafts = SessionSetEditing.drafts(for: [ex], unit: .kg)
        XCTAssertEqual(drafts[key(ex, 0)], SessionSetEditing.Draft(reps: "5", weight: "62.5"))
        XCTAssertEqual(drafts[key(ex, 1)], SessionSetEditing.Draft(reps: "12", weight: ""))
    }

    func testDraftWeightSeedsInThePreferredDisplayUnit() {
        // Stored 60 kg viewed with lb preferred: the field shows what the tile shows (the
        // converted value, the hint's one-decimal rounding), not the raw stored number.
        let ex = exercise("bench", [set(8, 60)])
        let drafts = SessionSetEditing.drafts(for: [ex], unit: .lb)
        XCTAssertEqual(drafts[key(ex, 0)], SessionSetEditing.Draft(reps: "8", weight: "132.3"))
    }

    // MARK: - Apply

    func testApplyCorrectsOnlyTheDraftedValues() {
        let ex = exercise("bench", [set(8, 1000), set(8, 60)])
        var drafts = SessionSetEditing.drafts(for: [ex], unit: .kg)
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "8", weight: "100")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex], unit: .kg)
        XCTAssertEqual(fixed[0].sets[0].actualWeight, 100, "the fat-fingered 1000 is corrected")
        XCTAssertEqual(fixed[0].sets[1].actualWeight, 60, "untouched draft round-trips unchanged")
        XCTAssertEqual(fixed[0].sets[0].completedAt, ex.sets[0].completedAt,
                       "completion stamp survives the edit")
        XCTAssertEqual(fixed[0].sets[0].weightUnit, .kg, "unit = the unit the field displayed")
    }

    func testApplyParsesWithThePlayersRules() {
        let ex = exercise("bench", [set(8, 60)])
        var drafts = SessionSetEditing.drafts(for: [ex], unit: .kg)
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: " 9 ", weight: "62,5")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex], unit: .kg)
        XCTAssertEqual(fixed[0].sets[0].actualReps, 9, "whitespace-trimmed like the player")
        XCTAssertEqual(fixed[0].sets[0].actualWeight, 62.5, "decimal comma accepted like the player")
    }

    func testApplyNonNumericTextClearsTheValueLikeThePlayer() {
        let ex = exercise("bench", [set(8, 60)])
        var drafts = SessionSetEditing.drafts(for: [ex], unit: .kg)
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "abc", weight: "")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex], unit: .kg)
        XCTAssertNil(fixed[0].sets[0].actualReps)
        XCTAssertNil(fixed[0].sets[0].actualWeight)
    }

    func testApplyWithNoDraftsIsIdentity() {
        let ex = exercise("bench", [set(8, 60)])
        XCTAssertEqual(SessionSetEditing.apply(drafts: [:], to: [ex], unit: .kg), [ex])
    }

    // MARK: - Preferred-unit round trip (kg-stored history viewed in lb)

    func testUntouchedDraftsRoundTripBitIdenticalAcrossUnits() {
        // Save without editing anything: the seeded "132.3" must NOT be parsed back as 132.3 lb
        // (≈ 60.01 kg) — untouched sets stay bit-identical to what was stored.
        let ex = exercise("bench", [set(8, 60), set(6, 62.5)])
        let drafts = SessionSetEditing.drafts(for: [ex], unit: .lb)
        XCTAssertEqual(SessionSetEditing.apply(drafts: drafts, to: [ex], unit: .lb), [ex])
    }

    func testEditedDraftStoresTheTypedNumberInThePreferredUnit() {
        let ex = exercise("bench", [set(8, 60)])   // stored in kg
        var drafts = SessionSetEditing.drafts(for: [ex], unit: .lb)
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "8", weight: "135")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex], unit: .lb)
        XCTAssertEqual(fixed[0].sets[0].actualWeight, 135, "the typed number is stored as typed…")
        XCTAssertEqual(fixed[0].sets[0].weightUnit, .lb, "…in the unit the field displayed")
    }

    // MARK: - Downstream stats recompute from the stored fix (in-memory SwiftData)

    func testCorrectedSetChangesPersistedVolumeAndPR() throws {
        let context = container.mainContext
        let ex = exercise("bench", [set(8, 1000), set(8, 60)])
        let session = WorkoutSession(routineName: "Push Day",
                                     startedAt: Date(timeIntervalSince1970: 0),
                                     completedAt: Date(timeIntervalSince1970: 3600),
                                     exercises: [ex])
        context.insert(session)
        try context.save()
        XCTAssertEqual(WorkoutMath.topSet(history: [session], exerciseId: "bench")?.bestKg, 1000)

        var drafts = SessionSetEditing.drafts(for: session.exercises, unit: .kg)
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "8", weight: "100")
        session.exercises = SessionSetEditing.apply(drafts: drafts, to: session.exercises, unit: .kg)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(WorkoutMath.topSet(history: [fetched], exerciseId: "bench")?.bestKg, 100,
                       "the PR recomputes from the corrected stored value")
        XCTAssertEqual(WorkoutMath.sessionVolumeKg(fetched), 8 * 100 + 8 * 60,
                       "session volume recomputes from the corrected stored value")
    }
}
