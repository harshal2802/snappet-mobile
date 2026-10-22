import XCTest
import SwiftData
@testable import Snappet

/// Logging from Shortcuts / Siri / links (prompt 199).
@MainActor
final class WorkoutIntentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // Last week's bench: 3 × 8 @ 75 kg, and a named climb.
        var bench = SessionExercise(exerciseId: "Barbell_Bench_Press_-_Medium_Grip", targetSets: 0, targetReps: "",
                                    targetRestSeconds: 0, sets: [], kindRaw: SetKind.repsWeight.rawValue)
        bench.sets = (0..<3).map { _ in SetLog(actualReps: 8, actualWeight: 75, weightUnit: .kg, completedAt: now.addingTimeInterval(-7 * 86_400)) }
        var climb = LibraryCreate.climb(AddClimbParams(type: .boulder, scale: .vScale, grade: "V4", name: "Blue arete",
                                                       gym: "Gravity", wall: "Slab", color: .blue))
        var attempt = SetLog(climbGradeLabel: "V4", climbStatusRaw: "attempt")
        attempt.completedAt = now.addingTimeInterval(-7 * 86_400)
        climb.sets = [attempt]
        let past = WorkoutSession(routineName: "Push Day", startedAt: now.addingTimeInterval(-7 * 86_400),
                                  completedAt: now.addingTimeInterval(-7 * 86_400 + 3600), exercises: [bench, climb])
        context.insert(past)
        try context.save()
    }

    func testLogASetStartsAQuickSessionAndRepeatsLastTime() throws {
        XCTAssertNil(WorkoutIntentService.runningSession(in: context))
        let out = try WorkoutIntentService.logSet(activity: "bench press", in: context, now: now)
        XCTAssertTrue(out.startedSession)
        let running = try XCTUnwrap(WorkoutIntentService.runningSession(in: context))
        XCTAssertEqual(running.routineName, "Quick session")
        XCTAssertEqual(running.exercises.count, 1)
        let set = try XCTUnwrap(running.exercises[0].sets.first)
        XCTAssertEqual(set.actualReps, 8, "repeats the last set")
        XCTAssertEqual(set.actualWeight, 75)
        XCTAssertTrue(out.message.contains("Bench Press"), out.message)

        // A second log lands on the same entity, with the given numbers.
        let again = try WorkoutIntentService.logSet(activity: "bench press", reps: 6, weight: 80, in: context, now: now)
        XCTAssertFalse(again.startedSession)
        XCTAssertEqual(running.exercises.count, 1)
        XCTAssertEqual(running.exercises[0].sets.map(\.actualWeight), [75, 80])
    }

    func testLogAClimbAttempt() throws {
        let out = try WorkoutIntentService.logAttempt(climb: "Blue arete", outcome: .sent, in: context, now: now)
        XCTAssertTrue(out.message.contains("Blue arete"), out.message)
        let ex = try XCTUnwrap(WorkoutIntentService.runningSession(in: context)?.exercises.first)
        XCTAssertEqual(ex.climbGradeLabel, "V4", "set up as last time")
        XCTAssertEqual(ex.sets.last?.climbStatusRaw, "sent")
    }

    func testErrors() {
        XCTAssertThrowsError(try WorkoutIntentService.logSet(activity: "Underwater basket weaving", in: context)) {
            XCTAssertEqual($0 as? WorkoutIntentService.Failure, .unknownActivity("Underwater basket weaving"))
        }
        XCTAssertThrowsError(try WorkoutIntentService.logAttempt(climb: "bench press", outcome: .sent, in: context)) {
            XCTAssertEqual($0 as? WorkoutIntentService.Failure, .notAClimb("bench press"))
        }
    }

    func testTheSetBuilder() {
        let last = SetLog(actualReps: 8, actualWeight: 75, weightUnit: .kg)
        XCTAssertEqual(IntentSetBuilder.set(kind: .repsWeight, discipline: .strength, reps: nil, weight: 80, unit: .kg,
                                            seconds: nil, meters: nil, last: last, now: now)?.actualReps, 8)
        XCTAssertNil(IntentSetBuilder.set(kind: .repsWeight, discipline: .strength, reps: nil, weight: nil, unit: .kg,
                                          seconds: nil, meters: nil, last: nil, now: now), "nothing to log")
        let run = IntentSetBuilder.set(kind: .duration, discipline: .run, reps: nil, weight: nil, unit: .kg,
                                       seconds: 1500, meters: 5000, last: nil, now: now)
        XCTAssertEqual(run?.distanceMeters, 5000)
        XCTAssertEqual(run?.completedAt, now)
    }

    func testWorkoutLinks() {
        XCTAssertEqual(WorkoutLinkAction(url: URL(string: "snappet://quick")!), .quick(activity: nil))
        XCTAssertEqual(WorkoutLinkAction(url: URL(string: "snappet://quick?activity=Bench%20Press")!), .quick(activity: "Bench Press"))
        XCTAssertEqual(WorkoutLinkAction(url: URL(string: "snappet://finish")!), .finish)
        XCTAssertEqual(WorkoutLinkAction(url: URL(string: "snappet://log?activity=Bench&reps=8&weight=75&unit=lb")!),
                       .log(activity: "Bench", reps: 8, weight: 75, unit: .lb, seconds: nil, meters: nil))
        XCTAssertEqual(WorkoutLinkAction(url: URL(string: "snappet://attempt?climb=Blue%20arete&outcome=Sent")!),
                       .attempt(climb: "Blue arete", outcome: .sent))
        XCTAssertNil(WorkoutLinkAction(url: URL(string: "snappet://log?reps=8")!), "no activity")
        XCTAssertNil(WorkoutLinkAction(url: URL(string: "https://example.com/log?activity=x")!))
        XCTAssertEqual(SnappetDeepLink.route(for: URL(string: "snappet://finish")!), .workout(.finish))
    }

    func testActionsRouteToTheGymTracker() {
        XCTAssertEqual(AppActionRouter.route(for: .startQuickSession("x")).moduleID, "workout-log")
        XCTAssertEqual(AppActionRouter.route(for: .finishSession).moduleID, "workout-log")
        // A link from a photo shared to Snappet routes itself through the shell's link router (prompt 201).
        XCTAssertNil(AppActionRouter.route(for: .openLink("snappet://finish")).moduleID)
        let data = try? JSONEncoder().encode(PendingAppAction.openLink("snappet://kilter/climb/x"))
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(PendingAppAction.self, from: $0) },
                       .openLink("snappet://kilter/climb/x"))
    }

    /// The `snappet://log` path end-to-end against the UI-test seed: route → resolve "Bench" → logged + worded the
    /// way the player's ledger shows it.
    func testTheLogLinkAgainstTheSeededHistory() throws {
        let c = try ModelContainer(for: Schema(SnappetSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        RoutineHistorySeed.seed(into: c.mainContext, now: now)
        guard case .workout(.log(let activity, let reps, let weight, let unit, let seconds, let meters))? =
                SnappetDeepLink.route(for: URL(string: "snappet://log?activity=Bench&reps=5&weight=82.5")!) else {
            return XCTFail("not routed as a workout log")
        }
        let out = try WorkoutIntentService.logSet(activity: activity, reps: reps, weight: weight, unit: unit,
                                                  seconds: seconds, meters: meters, in: c.mainContext, now: now)
        XCTAssertTrue(out.startedSession)
        XCTAssertTrue(out.message.hasPrefix("Logged 5 × 82.5 kg on "), out.message)
        XCTAssertTrue(out.message.contains("Bench"), out.message)
    }
}
