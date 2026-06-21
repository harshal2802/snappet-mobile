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

    // R7 — b4 must NOT fire for a running/timed exercise that incidentally carries a weight; a genuine
    // strength lift still fires.
    func testLiftPRSkipsRunningAndTimedDisciplines() {
        func run(dayOffset: Int, discipline: String, name: String, weight: Double) -> WorkoutSessionInput {
            let date = t0.addingTimeInterval(Double(dayOffset) * 86_400)
            let set = WorkoutSetInput(actualReps: 5, actualWeight: weight, completedAt: date)
            let ex = WorkoutExerciseInput(exerciseId: name, disciplineRaw: discipline, displayName: name, sets: [set])
            return WorkoutSessionInput(id: UUID(), routineName: "Mixed", startedAt: date,
                                       completedAt: date.addingTimeInterval(3_000), exercises: [ex])
        }
        // A "run" exercise that escalates weight every day — would be 2 PRs if the gate were absent.
        let r1 = run(dayOffset: 0, discipline: "run", name: "Treadmill", weight: 5)
        let r2 = run(dayOffset: 1, discipline: "run", name: "Treadmill", weight: 10)
        let t1 = run(dayOffset: 2, discipline: "timed", name: "Plank", weight: 5)
        let t2 = run(dayOffset: 3, discipline: "timed", name: "Plank", weight: 10)
        let runTimed = FeedComposer.compose(workoutSessions: [r1, r2, t1, t2], now: t0.addingTimeInterval(5 * 86_400))
            .filter { $0.kind == .b4LiftPR }
        XCTAssertEqual(runTimed.count, 0, "running/timed exercises never fire a lift PR")

        // A genuine strength lift still fires (and carries the unit + previous est-1RM).
        func lift(dayOffset: Int, weight: Double, unit: String) -> WorkoutSessionInput {
            let date = t0.addingTimeInterval(Double(dayOffset) * 86_400)
            let set = WorkoutSetInput(actualReps: 5, actualWeight: weight, weightUnit: unit, completedAt: date)
            let ex = WorkoutExerciseInput(exerciseId: "bench", disciplineRaw: "strength", displayName: "Bench", sets: [set])
            return WorkoutSessionInput(id: UUID(), routineName: "Push", startedAt: date,
                                       completedAt: date.addingTimeInterval(3_000), exercises: [ex])
        }
        let l1 = lift(dayOffset: 0, weight: 80, unit: "lb")   // establishes
        let l2 = lift(dayOffset: 1, weight: 90, unit: "lb")   // PR
        let strength = FeedComposer.compose(workoutSessions: [l1, l2], now: t0.addingTimeInterval(3 * 86_400))
            .filter { $0.kind == .b4LiftPR }
        XCTAssertEqual(strength.count, 1, "a strength lift that beats prior best fires once")
        if case .liftPR(let p)? = strength.first?.payload {
            XCTAssertEqual(p.unit, "lb", "unit flows from the winning set")
            XCTAssertNotNil(p.previousOneRepMaxKg)
        } else { XCTFail("expected a liftPR payload") }
    }

    // R7 — b1 grade PR fires only when the send is a genuine all-time max grade (not for sends at or
    // below the running max).
    func testGradePRFiresOnlyAtAllTimeMax() {
        func send(_ uuid: String, _ grade: String, _ diff: Double, dayOffset: Int) -> KilterClimbLog {
            let at = t0.addingTimeInterval(Double(dayOffset) * 86_400)
            return KilterClimbLog(climbUUID: uuid, climbName: uuid, gradeLabel: grade, difficulty: diff,
                                  status: .sent, attempts: 1, startedAt: at, endedAt: at, loggedAt: at, angle: 40, sessionId: nil)
        }
        let logs = [
            send("a", "V4", 13, dayOffset: 0),   // first ever → all-time max ⇒ PR
            send("b", "V5", 16, dayOffset: 1),   // new all-time max ⇒ PR
            send("c", "V5", 16, dayOffset: 2),   // ties the max, NOT above ⇒ no PR
            send("d", "V3", 10, dayOffset: 3),   // below the max ⇒ no PR
            send("e", "V6", 19, dayOffset: 4),   // new all-time max ⇒ PR
        ]
        let prs = FeedComposer.compose(kilterLogs: logs, now: t0.addingTimeInterval(6 * 86_400))
            .filter { $0.kind == .b1GradePR }
        XCTAssertEqual(prs.count, 3, "PR fires only on a genuine new all-time max (V4, V5, V6)")
        let prGrades = Set(prs.compactMap { card -> String? in
            if case .gradePR(let p) = card.payload { return p.newGrade } else { return nil }
        })
        XCTAssertEqual(prGrades, ["V4", "V5", "V6"])
    }

    // R7 — b5 streak record variant: a current streak that beats the prior best ⇒ isRecord + previousBest;
    // a current streak that does NOT beat the prior best ⇒ not a record; the >=3 baseline still gates.
    func testStreakRecordVariant() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        func session(_ day: Date) -> KilterSessionInput {
            KilterSessionInput(id: UUID(), startedAt: day, angle: 40)
        }
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }

        // Prior run of 3 days (Jun 1–3), gap, then a CURRENT run of 5 days (Jun 10–14) ⇒ record (5 > 3).
        let recordDays = [day(2026,6,1), day(2026,6,2), day(2026,6,3),
                          day(2026,6,10), day(2026,6,11), day(2026,6,12), day(2026,6,13), day(2026,6,14)]
        let recordCards = FeedComposer.compose(kilterSessions: recordDays.map(session),
                                               now: day(2026,6,14), calendar: cal).filter { $0.kind == .b5Streak }
        XCTAssertEqual(recordCards.count, 1)
        if case .streak(let p)? = recordCards.first?.payload {
            XCTAssertEqual(p.days, 5)
            XCTAssertTrue(p.isRecord, "current 5-day run beats the prior best 3")
            XCTAssertEqual(p.previousBest, 3)
        } else { XCTFail("expected a streak payload") }

        // Prior run of 5 days (Jun 1–5), gap, then a CURRENT run of 3 days (Jun 10–12) ⇒ NOT a record.
        let nonRecordDays = [day(2026,6,1), day(2026,6,2), day(2026,6,3), day(2026,6,4), day(2026,6,5),
                             day(2026,6,10), day(2026,6,11), day(2026,6,12)]
        let nonRecordCards = FeedComposer.compose(kilterSessions: nonRecordDays.map(session),
                                                  now: day(2026,6,12), calendar: cal).filter { $0.kind == .b5Streak }
        XCTAssertEqual(nonRecordCards.count, 1, ">=3 baseline still emits the card")
        if case .streak(let p)? = nonRecordCards.first?.payload {
            XCTAssertEqual(p.days, 3)
            XCTAssertFalse(p.isRecord, "current 3-day run does not beat the prior best 5")
            XCTAssertEqual(p.previousBest, 5)
        } else { XCTFail("expected a streak payload") }

        // A 2-day current run never emits (>=3 eligibility), record or not.
        let twoDays = [day(2026,6,11), day(2026,6,12)]
        let none = FeedComposer.compose(kilterSessions: twoDays.map(session),
                                        now: day(2026,6,12), calendar: cal).filter { $0.kind == .b5Streak }
        XCTAssertTrue(none.isEmpty, "a 2-day streak is below the >=3 baseline")
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
