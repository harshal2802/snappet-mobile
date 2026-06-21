import XCTest
@testable import Snappet

/// F5: b4 Lift PR (Epley est-1RM) + a3 On-the-Board eligibility (pure).
final class FeedMilestoneTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func workout(dayOffset: Int, exerciseId: String, name: String, reps: Int, weight: Double) -> WorkoutSessionInput {
        let date = t0.addingTimeInterval(Double(dayOffset) * 86_400)
        let set = WorkoutSetInput(actualReps: reps, actualWeight: weight, completedAt: date)
        let ex = WorkoutExerciseInput(exerciseId: exerciseId, displayName: name, sets: [set])
        return WorkoutSessionInput(id: UUID(), routineName: "Push", startedAt: date,
                                   completedAt: date.addingTimeInterval(3_000), exercises: [ex])
    }

    func testLiftPRFiresOnlyWhenBeatingPrior() {
        let w1 = workout(dayOffset: 0, exerciseId: "bench", name: "Bench", reps: 5, weight: 80)  // establishes
        let w2 = workout(dayOffset: 1, exerciseId: "bench", name: "Bench", reps: 5, weight: 85)  // PR
        let w3 = workout(dayOffset: 2, exerciseId: "bench", name: "Bench", reps: 5, weight: 80)  // regress
        let prs = FeedComposer.compose(workoutSessions: [w1, w2, w3], now: t0.addingTimeInterval(3 * 86_400))
            .filter { $0.kind == .b4LiftPR }
        XCTAssertEqual(prs.count, 1, "only w2 beats a prior best")
        if case .liftPR(let p)? = prs.first?.payload {
            XCTAssertEqual(p.exerciseName, "Bench")
            XCTAssertGreaterThan(p.oneRepMaxKg, p.previousOneRepMaxKg ?? 0)
        } else { XCTFail("expected a liftPR payload") }
    }

    func testOnTheBoardOnlyWhenSessionHasNoLog() {
        let logged = UUID(), litOnly = UUID()
        let log = KilterClimbLog(climbUUID: "x", climbName: "x", gradeLabel: "V4", difficulty: 13,
                                 status: .sent, attempts: 1, startedAt: t0, endedAt: t0, loggedAt: t0, angle: 40, sessionId: logged)
        let lit = [
            LitEventInput(climbUUID: "a", gradeLabel: "V3", sessionId: logged.uuidString, litAt: t0),   // suppressed (logged)
            LitEventInput(climbUUID: "b", gradeLabel: "V4", sessionId: litOnly.uuidString, litAt: t0),
            LitEventInput(climbUUID: "c", gradeLabel: "V5", sessionId: litOnly.uuidString, litAt: t0.addingTimeInterval(60)),
        ]
        let board = FeedComposer.compose(kilterLogs: [log], kilterLitEvents: lit, now: t0.addingTimeInterval(86_400))
            .filter { $0.kind == .a3OnTheBoard }
        XCTAssertEqual(board.count, 1, "only the lit-only session yields an On-the-Board card")
        if case .onTheBoard(let p)? = board.first?.payload { XCTAssertEqual(p.litCount, 2) } else { XCTFail() }
    }
}
