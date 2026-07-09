import XCTest
@testable import Snappet

/// Unit tests for the **pure** `QuickSessionPager` logic (prompt 109) — the page list, plan
/// progress + nudge, rail chips, plan defaults, and history-drawer deltas. No SwiftData container,
/// no view, no device.
final class QuickSessionPagerTests: XCTestCase {

    // MARK: - Builders

    private func set(_ reps: Int? = nil, _ weight: Double? = nil, unit: WeightUnit? = .kg,
                     duration: Double? = nil, done: Bool = true) -> SetLog {
        SetLog(actualReps: reps, actualWeight: weight, weightUnit: unit,
               completedAt: done ? Date(timeIntervalSince1970: 0) : nil,
               durationSec: duration)
    }

    private func strength(_ id: String = "bench", sets: [SetLog] = [],
                          planned: Int? = nil) -> SessionExercise {
        var ex = SessionExercise(exerciseId: id, targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: sets,
                                 kindRaw: SetKind.repsWeight.rawValue)
        ex.plannedSets = planned
        return ex
    }

    private func climb(_ name: String = "Crimper", grade: String? = "V5",
                       sets: [SetLog] = []) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: sets, displayName: name,
                                 kindRaw: SetKind.climbAttempt.rawValue)
        ex.climbGradeLabel = grade
        return ex
    }

    private func timed(_ name: String = "Plank", structured: Bool = false,
                       sets: [SetLog] = [], planned: Int? = nil) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "adhoc-duration", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: sets, displayName: name,
                                 kindRaw: SetKind.duration.rawValue)
        if structured { ex.timedSpec = .tabata }
        ex.plannedSets = planned
        return ex
    }

    private func run(sets: [SetLog] = [], planned: Int? = nil) -> SessionExercise {
        var ex = SessionExercise(exerciseId: "adhoc-run", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: sets, displayName: "Run",
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.run.rawValue
        ex.plannedSets = planned
        return ex
    }

    private func session(_ exercises: [SessionExercise], daysAgo: Double,
                         completed: Bool = true) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
        return WorkoutSession(routineName: "Quick session", startedAt: start,
                              completedAt: completed ? start.addingTimeInterval(3600) : nil,
                              exercises: exercises)
    }

    // MARK: - Pages

    func testPagesAreOverviewExercisesInAddedOrderThenAdd() {
        let a = strength("bench"), b = climb(), c = timed()
        let pages = QuickSessionPager.pages(for: [a, b, c])
        XCTAssertEqual(pages, [.overview, .exercise(a.id), .exercise(b.id), .exercise(c.id), .add])
    }

    func testEmptySessionPagesAreOverviewAndAdd() {
        XCTAssertEqual(QuickSessionPager.pages(for: []), [.overview, .add])
    }

    func testPageForKnownExerciseAndUnknownFallsBackToAdd() {
        let a = strength()
        XCTAssertEqual(QuickSessionPager.page(for: a.id, in: [a]), .exercise(a.id))
        XCTAssertEqual(QuickSessionPager.page(for: UUID(), in: [a]), .add)
    }

    // MARK: - Plan state

    func testPlanStateCountsCompletedSetsAgainstPlan() {
        let ex = strength(sets: [set(8, 60), set(8, 60), set(done: false)], planned: 5)
        let plan = QuickSessionPager.planState(for: ex)
        XCTAssertEqual(plan, QuickSessionPager.PlanState(done: 2, planned: 5))
        XCTAssertFalse(plan!.isComplete)
        XCTAssertEqual(plan!.label(), "set 3 of 5")
    }

    func testPlanCompleteLabelAndFlag() {
        let ex = strength(sets: Array(repeating: set(8, 60), count: 5), planned: 5)
        let plan = QuickSessionPager.planState(for: ex)!
        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.label(), "5 of 5 ✓")
    }

    func testNoPlanLabelIsPlainCount() {
        XCTAssertEqual(QuickSessionPager.planState(for: strength(sets: [set(8, 60)]))!.label(),
                       "1 set")
        XCTAssertEqual(QuickSessionPager.planState(for: strength())!.label(), "0 sets")
    }

    func testClimbHasNoPlanState() {
        XCTAssertNil(QuickSessionPager.planState(for: climb()))
    }

    func testZeroPlannedNeverReadsComplete() {
        // Defensive: a 0 plan (shouldn't be persistable, but old blobs are forever) stays open.
        let ex = strength(sets: [set(8, 60)], planned: 0)
        XCTAssertFalse(QuickSessionPager.planState(for: ex)!.isComplete)
    }

    func testEffortNounPerDiscipline() {
        XCTAssertEqual(QuickSessionPager.effortNoun(for: strength()), "set")
        XCTAssertEqual(QuickSessionPager.effortNoun(for: run()), "leg")
        XCTAssertEqual(QuickSessionPager.effortNoun(for: climb()), "attempt")
        XCTAssertEqual(QuickSessionPager.effortNoun(for: timed(structured: true)), "round")
        XCTAssertEqual(QuickSessionPager.effortNoun(for: timed(structured: false)), "set")
    }

    // MARK: - Plan default

    func testDefaultPlanIsLastSessionsSetCount() {
        let old = session([strength(sets: [set(8, 50)])], daysAgo: 10)
        let recent = session([strength(sets: [set(8, 60), set(8, 60), set(8, 60)])], daysAgo: 2)
        XCTAssertEqual(QuickSessionPager.defaultPlan(exerciseId: "bench", displayName: nil,
                                                     history: [old, recent]), 3)
    }

    func testDefaultPlanIgnoresActiveSessionsAndOrder() {
        let live = session([strength(sets: [set(8, 70), set(8, 70)])], daysAgo: 0, completed: false)
        let done = session([strength(sets: [set(8, 60)])], daysAgo: 3)
        // Order of the array must not matter; the active session never counts.
        XCTAssertEqual(QuickSessionPager.defaultPlan(exerciseId: "bench", displayName: nil,
                                                     history: [live, done]), 1)
    }

    func testDefaultPlanNilWithoutPrecedent() {
        XCTAssertNil(QuickSessionPager.defaultPlan(exerciseId: "bench", displayName: nil, history: []))
    }

    func testAdhocDefaultPlanMatchesByDisplayName() {
        let plank = timed("Plank", sets: [set(duration: 60), set(duration: 60)])
        let hang = timed("Dead hang", sets: [set(duration: 30)])
        let past = session([plank, hang], daysAgo: 1)
        XCTAssertEqual(QuickSessionPager.defaultPlan(exerciseId: "adhoc-duration",
                                                     displayName: "Plank", history: [past]), 2)
        XCTAssertEqual(QuickSessionPager.defaultPlan(exerciseId: "adhoc-duration",
                                                     displayName: "Dead hang", history: [past]), 1)
        XCTAssertNil(QuickSessionPager.defaultPlan(exerciseId: "adhoc-duration",
                                                   displayName: "Wall sit", history: [past]))
    }

    // MARK: - Nudge (next incomplete)

    func testNextIncompleteScansForwardThenWraps() {
        let done = strength("bench", sets: [set(8, 60)], planned: 1)      // complete
        let cur = strength("squat", sets: [set(5, 100)], planned: 1)      // current (complete)
        let empty = climb()                                               // nothing logged
        XCTAssertEqual(QuickSessionPager.nextIncomplete(after: cur.id, in: [done, cur, empty]),
                       empty.id, "forward scan finds the empty climb")
        XCTAssertEqual(QuickSessionPager.nextIncomplete(after: empty.id, in: [done, cur, empty]),
                       nil, "wrap finds nothing when everything else is done")
    }

    func testNextIncompletePrefersPlanGapOverLoggedOpenEnded() {
        let cur = strength("bench", sets: [set(8, 60)], planned: 1)
        let openLogged = timed("Plank", sets: [set(duration: 60)])        // open-ended, has a set → finished
        let planGap = strength("squat", sets: [set(5, 100)], planned: 3)  // 1 of 3 → unfinished
        XCTAssertEqual(QuickSessionPager.nextIncomplete(after: cur.id, in: [cur, openLogged, planGap]),
                       planGap.id)
    }

    // MARK: - Rail chips

    func testRailChipsShapeAndOrder() {
        let bench = strength(sets: [set(8, 60), set(8, 60)], planned: 5)
        let boulder = climb(grade: "V5", sets: [set()])
        let chips = QuickSessionPager.railChips(for: [bench, boulder]) { ex in
            ex.displayName ?? "Bench Press"
        }
        XCTAssertEqual(chips.map(\.page),
                       [.overview, .exercise(bench.id), .exercise(boulder.id), .add])
        XCTAssertEqual(chips[1].title, "Bench")
        XCTAssertEqual(chips[1].detail, "2/5")
        XCTAssertFalse(chips[1].done)
        XCTAssertEqual(chips[2].title, "V5", "a graded climb chips as its grade")
        XCTAssertEqual(chips[2].detail, "1")
    }

    func testRailChipDoneWhenPlanMet() {
        let bench = strength(sets: [set(8, 60)], planned: 1)
        let chips = QuickSessionPager.railChips(for: [bench]) { _ in "Bench Press" }
        XCTAssertTrue(chips[1].done)
    }

    func testRailTitleTruncatesLongFirstWord() {
        let ex = strength()
        XCTAssertEqual(QuickSessionPager.railTitle(for: ex, name: "Stiff-legged-deadlift variant"),
                       "Stiff-leg…")
        XCTAssertEqual(QuickSessionPager.railTitle(for: ex, name: "Bench Press"), "Bench")
    }

    func testUngradedClimbRailTitleFallsBackToName() {
        let ex = climb("Cave Roof", grade: nil)
        XCTAssertEqual(QuickSessionPager.railTitle(for: ex, name: "Cave Roof"), "Cave")
    }

    // MARK: - Deltas

    func testWeightDeltasPerIndex() {
        let prev = [set(8, 60), set(8, 60), set(8, 60)]
        let cur = [set(8, 60), set(8, 62.5)]
        let deltas = QuickSessionPager.deltas(current: cur, previous: prev, kind: .repsWeight)
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(deltas[0]?.direction, .same)
        XCTAssertEqual(deltas[1]?.direction, .up)
        XCTAssertEqual(deltas[1]?.label, "▲ +2.5 kg")
    }

    func testDeltaNilWithoutCounterpartOrCrossUnit() {
        let prev = [SetLog(actualReps: 8, actualWeight: 132, weightUnit: .lb,
                           completedAt: Date(timeIntervalSince1970: 0))]
        let cur = [set(8, 60, unit: .kg), set(8, 60)]
        let deltas = QuickSessionPager.deltas(current: cur, previous: prev, kind: .repsWeight)
        XCTAssertNil(deltas[0], "cross-unit pairs don't diff")
        XCTAssertNil(deltas[1], "no counterpart set")
    }

    func testDurationDeltaFormatsAsTime() {
        let prev = [set(duration: 60)]
        let cur = [set(duration: 55)]
        let deltas = QuickSessionPager.deltas(current: cur, previous: prev, kind: .duration)
        XCTAssertEqual(deltas[0]?.direction, .down)
        XCTAssertEqual(deltas[0]?.label, "▼ −0:05")
    }

    func testClimbAttemptsNeverDelta() {
        let deltas = QuickSessionPager.deltas(current: [set()], previous: [set()],
                                              kind: .climbAttempt)
        XCTAssertEqual(deltas, [nil])
    }

    // MARK: - lastSessionSets

    func testLastSessionSetsMostRecentCompletedWins() {
        let old = session([strength(sets: [set(8, 50)])], daysAgo: 10)
        let recent = session([strength(sets: [set(8, 60)])], daysAgo: 2)
        let sets = QuickSessionPager.lastSessionSets(exerciseId: "bench", displayName: nil,
                                                     history: [recent, old])
        XCTAssertEqual(sets?.first?.actualWeight, 60)
    }

    func testLastSessionSetsSkipsEmptyRuns() {
        let emptyRun = session([strength()], daysAgo: 1)
        let logged = session([strength(sets: [set(8, 55)])], daysAgo: 5)
        let sets = QuickSessionPager.lastSessionSets(exerciseId: "bench", displayName: nil,
                                                     history: [emptyRun, logged])
        XCTAssertEqual(sets?.first?.actualWeight, 55,
                       "a session where the exercise was added but never logged is not precedent")
    }

    // MARK: - Page-recorded clip routing (prompt 113, #273)

    private func rec(_ id: String, at t: TimeInterval) -> RecordedClip {
        RecordedClip(localIdentifier: id, capturedAt: Date(timeIntervalSince1970: t),
                     durationSec: nil)
    }

    func testClipPinsToItsRecordTimeOwner() {
        // The whole point of #273: the plan depends only on the key the clip was queued under
        // (the page the recorder was presented from) — there is no "current page" input for a
        // late-landing Photos save to corrupt.
        let owner = UUID(), other = UUID()
        let plan = QuickSessionPager.pageClipAttachPlan(
            queued: [owner: [rec("clip-a", at: 100)]], liveExerciseIDs: [owner, other])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].exerciseID, owner)
        XCTAssertEqual(plan[0].clips.map(\.localIdentifier), ["clip-a"])
    }

    func testDeletedOwnerRoutesToSessionUnassignedNeverDropped() {
        // The exercise was removed while the save was in flight: the clip files to the session
        // (exerciseID nil) rather than being discarded or pinned to whatever page is current.
        let deleted = UUID()
        let plan = QuickSessionPager.pageClipAttachPlan(
            queued: [deleted: [rec("clip-b", at: 50)]], liveExerciseIDs: [UUID()])
        XCTAssertEqual(plan.count, 1)
        XCTAssertNil(plan[0].exerciseID)
        XCTAssertEqual(plan[0].clips.map(\.localIdentifier), ["clip-b"])
    }

    func testMultiOwnerBatchesAttachInRecordingOrder() {
        // Record on A, swipe to B, record again while A's save is still in flight: both groups
        // attach, each to its own owner, ordered by earliest capture.
        let a = UUID(), b = UUID()
        let plan = QuickSessionPager.pageClipAttachPlan(
            queued: [b: [rec("on-b", at: 200)], a: [rec("on-a", at: 100)]],
            liveExerciseIDs: [a, b])
        XCTAssertEqual(plan.map(\.exerciseID), [a, b])
    }

    func testClipsWithinAGroupSortByCaptureTime() {
        let owner = UUID()
        let plan = QuickSessionPager.pageClipAttachPlan(
            queued: [owner: [rec("late", at: 300), rec("early", at: 10)]],
            liveExerciseIDs: [owner])
        XCTAssertEqual(plan[0].clips.map(\.localIdentifier), ["early", "late"])
    }

    func testEmptyQueuesYieldNoPlan() {
        // The attach handler clears the queue, which re-fires onChange — an empty or
        // empty-valued queue must produce an empty plan (no infinite loop, no empty attach).
        XCTAssertEqual(QuickSessionPager.pageClipAttachPlan(queued: [:], liveExerciseIDs: []), [])
        XCTAssertEqual(QuickSessionPager.pageClipAttachPlan(queued: [UUID(): []],
                                                            liveExerciseIDs: []), [])
    }
}
