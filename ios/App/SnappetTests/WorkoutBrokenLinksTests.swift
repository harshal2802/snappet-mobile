import XCTest
import SwiftData
@testable import Snappet

/// Prompt 265: five broken links and stale states from the workout state-machine review. One section per finding:
/// F10 (the Watch leaves a racket face the phone has left), F11 (deleting a session stops its rally scans), F12 (a
/// planned Start while a workout runs asks), F13 (a reminder's Start now for a gone / empty routine says so), F15 (the
/// Live Activity opens the running workout, never over an open player or racket screen).
@MainActor
final class WorkoutBrokenLinksTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ id: UUID = UUID(), revision: Int) -> RacketWatchState {
        RacketWatchState(sessionID: id, revision: revision, sport: "Table tennis", unitNoun: "game", sideUs: "You",
                         sideThem: "Alex", note: nil,
                         surface: .start(.init(title: "Start game 1?", cameraReady: true, footnote: "")),
                         stillPlaying: nil, notice: nil)
    }

    // MARK: F10 — the Watch

    func testClearAllRidesTheWireAndIsNotAWorkoutMessage() {
        let m = RacketWatchMessage.clearAll(through: 42)
        XCTAssertEqual(RacketWatchMessage(payload: m.payload), m)
        XCTAssertNil(LiveWorkoutMessage(payload: m.payload), "the workout relay doesn't mistake it for one of its own")
        XCTAssertNil(RacketWatchMessage(payload: ["racketKind": "clearAll"]), "malformed: no revision")
    }

    func testClearAllDropsTheFaceUnlessItIsNewer() {
        XCTAssertTrue(RacketWatchFreshness.clearAllDrops(state(revision: 10), through: 10))
        XCTAssertTrue(RacketWatchFreshness.clearAllDrops(state(revision: 9), through: 10))
        XCTAssertFalse(RacketWatchFreshness.clearAllDrops(state(revision: 11), through: 10),
                       "a match the phone opened again after the clear was queued stays")
        XCTAssertFalse(RacketWatchFreshness.clearAllDrops(nil, through: 10))
    }

    func testAfterAClearAQueuedOldSnapshotCantBringTheFaceBack() {
        var f = RacketWatchFreshness()
        XCTAssertTrue(f.admits(state(revision: 5)))
        f.cleared(through: 10)
        XCTAssertFalse(f.admits(state(revision: 9)), "an old snapshot still in the transferUserInfo queue")
        XCTAssertFalse(f.admits(state(revision: 10)))
        XCTAssertTrue(f.admits(state(revision: 11)), "the phone's next snapshot shows again")
        f.cleared(through: 3)
        XCTAssertEqual(f.clearedThrough, 10, "a late, older clear never lowers the mark")
    }

    func testATapThePhoneDoesntAnswerLeavesTheFaceAfterTheWindow() {
        var f = RacketWatchFreshness()
        XCTAssertFalse(f.isStale(now: t0))
        f.tapped(at: t0)
        f.tapped(at: t0.addingTimeInterval(10))   // a second tap doesn't restart the wait
        XCTAssertFalse(f.isStale(now: t0.addingTimeInterval(RacketWatchFreshness.answerWindowSec - 1)))
        XCTAssertTrue(f.isStale(now: t0.addingTimeInterval(RacketWatchFreshness.answerWindowSec)))
        f.heard()
        XCTAssertFalse(f.isStale(now: t0.addingTimeInterval(600)), "the phone answered")
        f.tapped(at: t0)
        f.cleared(through: 1)
        XCTAssertFalse(f.isStale(now: t0.addingTimeInterval(600)), "a clear answers too")
    }

    func testATapToAPhoneOutOfRangeNeverLeavesTheFace() {
        XCTAssertTrue(RacketWatchFreshness.waitsForAnAnswer(phoneReachable: true))
        XCTAssertFalse(RacketWatchFreshness.waitsForAnAnswer(phoneReachable: false),
                       "queued for later: the face stays so scoring from the wrist still works")
    }

    func testThePhoneClearsAtLaunchAndWhenTheSessionEndsButNeverAnotherSessionsLiveFace() {
        let match = UUID(), other = UUID()
        XCTAssertTrue(RacketWatchClearRule.broadcasts(attached: nil, ending: nil), "launch: nothing attached yet")
        XCTAssertFalse(RacketWatchClearRule.broadcasts(attached: match, ending: nil),
                       "activation again while a racket screen is up")
        XCTAssertTrue(RacketWatchClearRule.broadcasts(attached: nil, ending: [match]))
        XCTAssertTrue(RacketWatchClearRule.broadcasts(attached: match, ending: [match, other]),
                      "discard deletes while the match page is still attached")
        XCTAssertFalse(RacketWatchClearRule.broadcasts(attached: other, ending: [match]))
        XCTAssertTrue(RacketWatchClearRule.answersWithClear(commandFor: match, attached: nil),
                      "a tap after an app kill is answered, not dropped")
        XCTAssertTrue(RacketWatchClearRule.answersWithClear(commandFor: match, attached: other))
        XCTAssertFalse(RacketWatchClearRule.answersWithClear(commandFor: match, attached: match))
    }

    // MARK: F11 — a deleted session's scans

    func testDeletingASessionPlansOnlyItsScansOut() {
        let doomed = UUID(), kept = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        let jobs = [(record: a, session: doomed), (record: b, session: kept), (record: c, session: doomed)]
        XCTAssertEqual(RacketScanSessionDrop.plan(jobs: jobs, running: a, deleting: doomed),
                       .init(remove: [a, c], cancelRunning: true))
        XCTAssertEqual(RacketScanSessionDrop.plan(jobs: jobs, running: b, deleting: doomed),
                       .init(remove: [a, c], cancelRunning: false), "another session's running scan carries on")
        XCTAssertEqual(RacketScanSessionDrop.plan(jobs: jobs, running: nil, deleting: UUID()),
                       .init(remove: [], cancelRunning: false))
    }

    func testTheCascadeTakesTheSessionsWaitingScanOutOfTheQueue() throws {
        let container = try ModelContainer(for: Schema(SnappetSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [], displayName: "Table tennis match",
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        var log = RacketRecordingLog(startedAt: t0)
        log.runs = [.init(startSec: 0, endSec: 600, endReasonRaw: nil)]
        log.endedAt = t0.addingTimeInterval(600)
        ex.racketRecordingLog = log
        let session = WorkoutSession(routineName: "Quick session", exercises: [ex])
        context.insert(session)
        try context.save()
        let store = RacketVideoStore(session: session, context: context)
        let center = RacketScanCenter.shared
        let ref = RacketPartRef(exerciseID: ex.id, title: "Recording", startSec: 0, endSec: 600, setIndex: nil)
        let ids = center.enqueue([ref], model: RacketCapabilityRegistry.placeholder, waitForCharger: true, store: store)
        guard let id = ids.first, center.isQueued(id), center.runningID != id else {
            center.forgetSession(session.id)
            throw XCTSkip("the simulator reports charging, so the scan started instead of waiting")
        }

        SessionCascade.deleteWorkoutSession(session, in: context)

        XCTAssertFalse(center.isQueued(id), "the deleted session's scan left the queue")
        XCTAssertTrue(center.deletedSessionIDs.contains(session.id), "a late result for it is dropped")
    }

    // MARK: F12 — a planned Start while a workout runs

    func testAPlannedStartAsksWhenAWorkoutIsRunning() {
        XCTAssertEqual(PlannedStart.decide(running: nil), .start)
        guard case .ask(let c) = PlannedStart.decide(running: "Quick session") else { return XCTFail("asks") }
        XCTAssertEqual(c.title, "A workout is already running")
        XCTAssertEqual(c.message, "“Quick session” is still going. Go to it, or cancel and start this plan after you "
                       + "finish it. Your plan stays here.")
        XCTAssertEqual(c.goTo, "Go to running workout")
        XCTAssertEqual(c.cancel, "Cancel")
        guard case .ask(let blank) = PlannedStart.decide(running: " ") else { return XCTFail("asks") }
        XCTAssertTrue(blank.message.hasPrefix("Your workout is still going."), blank.message)
    }

    // MARK: F13 — a reminder's Start now

    func testAReminderStartForAGoneOrEmptyRoutineSaysSo() {
        XCTAssertEqual(ReminderStart.outcome(routine: ("Push day", 3)), .start)
        XCTAssertEqual(ReminderStart.outcome(routine: nil), .notice(.init(
            title: "Routine not found",
            message: "This routine no longer exists. It may have been deleted, so there’s nothing to start.")))
        XCTAssertEqual(ReminderStart.outcome(routine: ("Leg day", 0)), .notice(.init(
            title: "Nothing to start", message: "“Leg day” has no exercises yet. Add some in Routines, then start it.")))
    }

    // MARK: F15 — the Live Activity

    func testTheLiveActivityLinkOpensTheWorkoutThroughTheShell() {
        XCTAssertEqual(WorkoutActivityAttributes.openURL.absoluteString, WorkoutLinkAction.openLink)
        XCTAssertEqual(WorkoutLinkAction(url: WorkoutActivityAttributes.openURL), .open)
        XCTAssertEqual(WorkoutLinkAction(url: URL(string: "SNAPPET://Workout")!), .open)
        XCTAssertNil(WorkoutLinkAction(url: URL(string: "snappet://workout/session/1")!), "only the bare link")
        XCTAssertEqual(SnappetDeepLink.route(for: WorkoutActivityAttributes.openURL), .workout(.open))
        XCTAssertEqual(AppActionRouter.route(for: .openWorkout),
                       .init(moduleID: "workout-log", resumeWorkout: true))
        XCTAssertFalse(AppActionRouter.route(for: .finishSession).resumeWorkout)
        let data = try? JSONEncoder().encode(PendingAppAction.openWorkout)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(PendingAppAction.self, from: $0) }, .openWorkout)
    }

    func testOpeningTheWorkoutNeverTearsDownAnOpenPlayerOrRacketScreen() {
        XCTAssertEqual(WorkoutOpenLink.decide(playerOpen: false, openCover: nil), .open)
        XCTAssertEqual(WorkoutOpenLink.decide(playerOpen: true, openCover: nil), .stay)
        for kind in [LiveCoverKind.recording, .drill, .game] {
            XCTAssertEqual(WorkoutOpenLink.decide(playerOpen: true, openCover: kind), .stay)
            XCTAssertEqual(WorkoutOpenLink.decide(playerOpen: false, openCover: kind), .stay,
                           "a cover reporting itself while the player flag lags")
        }
    }

    func testOpeningAModuleClearsThePlayerFlag() {
        let router = SuiteRouter()
        router.workoutPlayerOpen = true
        router.open(module: "kilter")
        XCTAssertFalse(router.workoutPlayerOpen, "replacing the stack takes the player down")
    }
}
