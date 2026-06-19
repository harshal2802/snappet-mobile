import XCTest
@testable import Snappet

/// Unit tests for the pure planner logic (workout-redesign E7): the "Today" readiness verb (REST/EASY/
/// TRAIN/PUSH), the recovery sharpener nudge, and the `Plan → [RoutineExercise]` bridge.
final class WorkoutPlanLogicTests: XCTestCase {

    private func signal(medianGap: Int? = 2) -> WorkoutHistoryStats {
        // Quads rested well beyond the untrained-freshness floor → unambiguously the freshest focus.
        WorkoutHistoryStats(daysSinceByDiscipline: [:], lastTrainedByDiscipline: [:], medianGapDays: medianGap,
                            daysSinceByMuscle: [.quadriceps: 12, .chest: 1], lastTrainedByMuscle: [:],
                            weeklyVolumeByMuscle: [:])
    }

    // MARK: - Readiness verb

    func testTrainedTodayIsRest() {
        let t = WorkoutPlanLogic.today(signal: signal(), daysSinceLastSession: 0)
        XCTAssertEqual(t.readiness, .rest)
    }

    func testUnderCadenceIsEasy() {
        // cadence 3; only 1 day rested → easy.
        let t = WorkoutPlanLogic.today(signal: signal(medianGap: 3), daysSinceLastSession: 1)
        XCTAssertEqual(t.readiness, .easy)
    }

    func testOnCadenceIsTrain() {
        let t = WorkoutPlanLogic.today(signal: signal(medianGap: 2), daysSinceLastSession: 2)
        XCTAssertEqual(t.readiness, .train)
    }

    func testWellRestedIsPush() {
        let t = WorkoutPlanLogic.today(signal: signal(medianGap: 2), daysSinceLastSession: 6)
        XCTAssertEqual(t.readiness, .push)
    }

    func testNeverTrainedDefaultsToTrain() {
        let t = WorkoutPlanLogic.today(signal: signal(medianGap: nil), daysSinceLastSession: nil)
        XCTAssertEqual(t.readiness, .train)
        XCTAssertFalse(t.why.isEmpty)
    }

    func testFocusMusclesSurfacedInToday() {
        let t = WorkoutPlanLogic.today(signal: signal(), daysSinceLastSession: 3)
        XCTAssertEqual(t.focusMuscles.first, .quadriceps, "The freshest muscle leads the focus")
    }

    // MARK: - Recovery sharpener nudge (optional)

    func testLowRecoveryCapsPushToTrain() {
        let pushNoRecovery = WorkoutPlanLogic.today(signal: signal(), daysSinceLastSession: 6)
        XCTAssertEqual(pushNoRecovery.readiness, .push)
        let withLowRecovery = WorkoutPlanLogic.today(signal: signal(), daysSinceLastSession: 6,
                                                     recoveryFraction: 0.2)
        XCTAssertEqual(withLowRecovery.readiness, .train, "A poor recovery read steps PUSH down to TRAIN")
    }

    func testHighRecoveryLiftsEasyToTrain() {
        let lifted = WorkoutPlanLogic.today(signal: signal(medianGap: 3), daysSinceLastSession: 1,
                                            recoveryFraction: 0.9)
        XCTAssertEqual(lifted.readiness, .train, "A strong recovery read lifts EASY to TRAIN")
    }

    func testNilRecoveryIsIgnored() {
        let a = WorkoutPlanLogic.today(signal: signal(), daysSinceLastSession: 6, recoveryFraction: nil)
        let b = WorkoutPlanLogic.today(signal: signal(), daysSinceLastSession: 6)
        XCTAssertEqual(a.readiness, b.readiness)
    }

    func testRampPositionOrders() {
        XCTAssertLessThan(WorkoutPlanLogic.Readiness.rest.rampPosition,
                          WorkoutPlanLogic.Readiness.push.rampPosition)
    }

    // MARK: - Plan → routine bridge

    func testRoutineExercisesPreserveOrderAndPrescription() {
        let c1 = WorkoutRecommender.Candidate(id: "squat", name: "Squat", primaryMuscles: [.quadriceps],
                                              equipment: .barbell, isCompound: true, isBodyweight: false)
        let c2 = WorkoutRecommender.Candidate(id: "curl", name: "Curl", primaryMuscles: [.biceps],
                                              equipment: .dumbbell, isCompound: false, isBodyweight: false)
        let plan = WorkoutRecommender.Plan(picks: [
            WorkoutRecommender.Pick(candidate: c1, goal: .main, sets: 4, reps: "5", restSeconds: 180),
            WorkoutRecommender.Pick(candidate: c2, goal: .accessory, sets: 3, reps: "10", restSeconds: 75)
        ], focusMuscles: [.quadriceps])

        let routine = WorkoutPlanLogic.routineExercises(from: plan, nameFor: { $0 == "squat" ? "Squat" : "Curl" })
        XCTAssertEqual(routine.count, 2)
        XCTAssertEqual(routine[0].exerciseId, "squat")
        XCTAssertEqual(routine[0].sets, 4)
        XCTAssertEqual(routine[0].reps, "5")
        XCTAssertEqual(routine[0].restSeconds, 180)
        XCTAssertEqual(routine[0].displayName, "Squat")
        // Plan exercises are strength blocks — disciplineRaw stays nil (the additive-nil invariant).
        XCTAssertEqual(routine[0].discipline, .strength)
        XCTAssertNil(routine[0].disciplineRaw)
        XCTAssertEqual(routine[1].exerciseId, "curl")
    }

    func testDefaultRoutineNameFoldsVerbAndDate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = WorkoutPlanLogic.defaultRoutineName(readiness: .push, date: date, calendar: cal)
        XCTAssertTrue(name.contains("Push"), "Name folds the verb")
    }
}
