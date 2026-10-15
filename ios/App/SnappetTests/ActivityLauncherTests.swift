import XCTest
@testable import Snappet

/// `ActivityLauncher` — the Activity page's Log it now / Add to routine (Library redesign L2, prompt 184).
final class ActivityLauncherTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(daysAgo: Double, _ ex: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        let done = ex.map { e -> SessionExercise in
            var e = e
            for i in e.sets.indices { e.sets[i].completedAt = start }
            return e
        }
        return WorkoutSession(routineName: "S", startedAt: start, completedAt: start.addingTimeInterval(3600), exercises: done)
    }

    private func bench(_ sets: [(Int, Double)]) -> SessionExercise {
        SessionExercise(exerciseId: "bench", targetSets: 0, targetReps: "", targetRestSeconds: 120,
                        sets: sets.map { SetLog(actualReps: $0.0, actualWeight: $0.1, weightUnit: .kg) })
    }

    private func climb() -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                sets: [SetLog(climbGradeLabel: "V5", climbStatusRaw: "sent")],
                                displayName: "Blue crimp", kindRaw: SetKind.climbAttempt.rawValue)
        e.gym = "Gravity"; e.wall = "Cave"; e.climbGradeLabel = "V5"; e.climbColorRaw = ClimbColor.blue.rawValue
        return e
    }

    private let benchKey = ActivityKey(exerciseId: "bench", nameKey: "")

    // MARK: - Log it now

    func testLogItNowClonesTheLatestClimbWithoutItsAttempts() throws {
        let old = climb(), latest = climb()
        let history = [session(daysAgo: 9, [old]), session(daysAgo: 2, [latest])]
        let ids = ActivityIdentity(sessions: history)
        let key = try XCTUnwrap(ids.key(for: latest))
        let ex = try XCTUnwrap(ActivityLauncher.sessionExercise(for: key, history: history, identity: ids))
        XCTAssertNotEqual(ex.id, latest.id, "a brand-new entity")
        XCTAssertTrue(ex.sets.isEmpty)
        XCTAssertEqual(ex.displayName, "Blue crimp")
        XCTAssertEqual(ex.gym, "Gravity"); XCTAssertEqual(ex.wall, "Cave"); XCTAssertEqual(ex.climbGradeLabel, "V5")
        XCTAssertEqual(ex.climbColor, .blue)
        XCTAssertNil(ex.plannedSets, "attempts aren't planned")
        // Logged today it lands in the same climb (same set window).
        XCTAssertEqual(ids.key(for: ex, loggedAt: now), key)
    }

    func testLogItNowPlansLastTimesSetCount() throws {
        let history = [session(daysAgo: 1, [bench([(8, 60), (8, 62.5), (6, 65)])])]
        let ex = try XCTUnwrap(ActivityLauncher.sessionExercise(for: benchKey, history: history,
                                                                identity: ActivityIdentity(sessions: history)))
        XCTAssertEqual(ex.exerciseId, "bench")
        XCTAssertEqual(ex.plannedSets, 3)
    }

    func testANeverLoggedCatalogMoveStartsBlank() throws {
        let ex = try XCTUnwrap(ActivityLauncher.sessionExercise(for: benchKey, history: [],
                                                                identity: ActivityIdentity(sessions: [])))
        XCTAssertEqual(ex.exerciseId, "bench")
        XCTAssertEqual(ex.kind, .repsWeight)
        XCTAssertTrue(ex.sets.isEmpty)
    }

    func testFestivalsAndOverviewsCantBeLaunched() {
        XCTAssertFalse(ActivityLauncher.canLaunch(ActivityKey(exerciseId: "festival-set", nameKey: "lost lands")))
        XCTAssertFalse(ActivityLauncher.canLaunch(.discipline(.climb)))
        XCTAssertTrue(ActivityLauncher.canLaunch(benchKey))
    }

    // MARK: - Add to routine

    func testRoutineBlockPrescribesLastTime() throws {
        let history = [session(daysAgo: 1, [bench([(8, 60), (8, 62.5), (6, 65)])])]
        let block = try XCTUnwrap(ActivityLauncher.routineBlock(for: benchKey, history: history,
                                                                identity: ActivityIdentity(sessions: history),
                                                                defaultUnit: .kg))
        XCTAssertEqual(block.exerciseId, "bench")
        XCTAssertEqual(block.sets, 3)
        XCTAssertEqual(block.reps, "8")
        XCTAssertEqual(block.weight, 65, "the top weight")
        XCTAssertEqual(block.restSeconds, 120)
    }

    func testRoutineBlockForAClimbKeepsItsGrade() throws {
        let c = climb()
        let history = [session(daysAgo: 1, [c])]
        let ids = ActivityIdentity(sessions: history)
        let block = try XCTUnwrap(ActivityLauncher.routineBlock(for: ids.key(for: c)!, history: history, identity: ids,
                                                                defaultUnit: .kg))
        XCTAssertEqual(block.discipline, .climb)
        XCTAssertEqual(block.climbGradeLabel, "V5")
        XCTAssertEqual(block.displayName, "Blue crimp")
    }

    func testRoutineBlockForATimedHoldKeepsItsProtocol() throws {
        var hang = SessionExercise(exerciseId: "adhoc-duration", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                   sets: [SetLog(durationSec: 10), SetLog(durationSec: 12)], displayName: "Max hangs",
                                   kindRaw: SetKind.duration.rawValue)
        hang.timedCategory = TimedExerciseCategory.hangboard.rawValue
        let history = [session(daysAgo: 1, [hang])]
        let key = ActivityKey(exerciseId: "adhoc-duration", nameKey: "max hangs")
        let block = try XCTUnwrap(ActivityLauncher.routineBlock(for: key, history: history,
                                                                identity: ActivityIdentity(sessions: history),
                                                                defaultUnit: .kg))
        XCTAssertEqual(block.discipline, .timed)
        XCTAssertEqual(block.sets, 2)
        XCTAssertEqual(block.targetDurationSec, 12)
        XCTAssertEqual(block.timedCategory, "hangboard")
    }
}
