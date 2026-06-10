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

    func testDraftsCoverOnlyCompletedRepsWeightSets() {
        let bench = exercise("bench", [set(8, 60), set(nil, nil, done: false)])
        let plank = exercise("plank", [SetLog(completedAt: .now, durationSec: 60)], kind: .duration)
        let skipped = exercise("row", [set(10, 40)], skipped: true)
        let drafts = SessionSetEditing.drafts(for: [bench, plank, skipped])

        XCTAssertEqual(drafts.count, 1, "only bench set 1 is editable")
        XCTAssertEqual(drafts[key(bench, 0)], SessionSetEditing.Draft(reps: "8", weight: "60"))
    }

    func testDraftTextFormatsLikeThePlayer() {
        // 62.5 keeps its decimal, nil fields become empty text (the player's blank state).
        let ex = exercise("ohp", [set(5, 62.5), set(12, nil)])
        let drafts = SessionSetEditing.drafts(for: [ex])
        XCTAssertEqual(drafts[key(ex, 0)], SessionSetEditing.Draft(reps: "5", weight: "62.5"))
        XCTAssertEqual(drafts[key(ex, 1)], SessionSetEditing.Draft(reps: "12", weight: ""))
    }

    // MARK: - Apply

    func testApplyCorrectsOnlyTheDraftedValues() {
        let ex = exercise("bench", [set(8, 1000), set(8, 60)])
        var drafts = SessionSetEditing.drafts(for: [ex])
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "8", weight: "100")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex])
        XCTAssertEqual(fixed[0].sets[0].actualWeight, 100, "the fat-fingered 1000 is corrected")
        XCTAssertEqual(fixed[0].sets[1].actualWeight, 60, "untouched draft round-trips unchanged")
        XCTAssertEqual(fixed[0].sets[0].completedAt, ex.sets[0].completedAt,
                       "completion stamp survives the edit")
        XCTAssertEqual(fixed[0].sets[0].weightUnit, .kg, "unit survives the edit")
    }

    func testApplyParsesWithThePlayersRules() {
        let ex = exercise("bench", [set(8, 60)])
        var drafts = SessionSetEditing.drafts(for: [ex])
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: " 9 ", weight: "62,5")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex])
        XCTAssertEqual(fixed[0].sets[0].actualReps, 9, "whitespace-trimmed like the player")
        XCTAssertEqual(fixed[0].sets[0].actualWeight, 62.5, "decimal comma accepted like the player")
    }

    func testApplyNonNumericTextClearsTheValueLikeThePlayer() {
        let ex = exercise("bench", [set(8, 60)])
        var drafts = SessionSetEditing.drafts(for: [ex])
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "abc", weight: "")

        let fixed = SessionSetEditing.apply(drafts: drafts, to: [ex])
        XCTAssertNil(fixed[0].sets[0].actualReps)
        XCTAssertNil(fixed[0].sets[0].actualWeight)
    }

    func testApplyWithNoDraftsIsIdentity() {
        let ex = exercise("bench", [set(8, 60)])
        XCTAssertEqual(SessionSetEditing.apply(drafts: [:], to: [ex]), [ex])
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

        var drafts = SessionSetEditing.drafts(for: session.exercises)
        drafts[key(ex, 0)] = SessionSetEditing.Draft(reps: "8", weight: "100")
        session.exercises = SessionSetEditing.apply(drafts: drafts, to: session.exercises)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(WorkoutMath.topSet(history: [fetched], exerciseId: "bench")?.bestKg, 100,
                       "the PR recomputes from the corrected stored value")
        XCTAssertEqual(WorkoutMath.sessionVolumeKg(fetched), 8 * 100 + 8 * 60,
                       "session volume recomputes from the corrected stored value")
    }
}
