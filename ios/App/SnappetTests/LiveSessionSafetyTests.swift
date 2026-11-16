import XCTest
@testable import Snappet

/// Prompt 263: the live session never loses work silently. One section per finding of the workout state-machine
/// review: F5 (remove asks), F2 (finish never deletes silently; the intent saves), F4 (the intent refuses while a racket
/// cover is open), F3 (the drawer's racket delete keeps every index right), F1 (one recording per entry; a drill
/// continues its log), F14 (a recording left open by a crash is closed at its last saved part).
final class LiveSessionSafetyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func game(_ f: Int?, _ a: Int?, end: Double, duration: Double? = nil) -> SetLog {
        var s = SetLog(completedAt: t0.addingTimeInterval(end), durationSec: duration)
        s.scoreFor = f; s.scoreAgainst = a
        if f == nil { s.scoreUnconfirmed = true }
        return s
    }

    private func match(sets: [SetLog] = [], log: RacketRecordingLog? = nil) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: sets, displayName: RacketStats.matchActivityName(.tableTennis),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = "Alex"
        ex.racketBestOf = 5
        ex.racketRecordingLog = log
        return ex
    }

    private func drill(sets: [SetLog] = [], log: RacketRecordingLog? = nil, recording: RacketRecordingMode = .everything) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.drillExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 60, sets: sets, displayName: "Forehand loop",
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.drill.rawValue
        ex.racketRecordingRaw = recording == .byUnit ? nil : recording.rawValue
        ex.racketRecordingLog = log
        return ex
    }

    private func lift(sets: Int = 0) -> SessionExercise {
        SessionExercise(exerciseId: "bench", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                        sets: (0..<sets).map { _ in SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg) },
                        displayName: "Bench Press", kindRaw: SetKind.repsWeight.rawValue)
    }

    private func recordedLog(mode: RacketRecordingMode = .everything, base: Int? = 0) -> RacketRecordingLog {
        var l = RacketRecordingLog(startedAt: t0)
        l.baseSetIndex = base
        l.runs = [.init(startSec: 0, endSec: 600, endReasonRaw: nil)]
        l.endedAt = t0.addingTimeInterval(600)
        if mode == .byUnit { l.modeRaw = mode.rawValue }
        return l
    }

    // MARK: - F5 remove asks

    func testRemovingAnEmptyExerciseNeedsNoConfirmation() {
        XCTAssertNil(LiveRemoval.prompt(for: lift(), name: "Bench Press", mediaCount: 0))
        XCTAssertNil(LiveRemoval.prompt(for: match(), name: "Table tennis", mediaCount: 0), "a match with no games")
    }

    func testRemovingAnExerciseWithSetsOrMediaAsksLikeTheSessionDetail() {
        let sets = LiveRemoval.prompt(for: lift(sets: 2), name: "Bench Press", mediaCount: 0)
        XCTAssertEqual(sets, LiveRemovalPrompt(title: "Remove Bench Press?", confirm: "Remove Bench Press",
                                               message: "Its sets are deleted from this session. Its photos and videos stay, under General."))
        let media = LiveRemoval.prompt(for: lift(), name: "Bench Press", mediaCount: 1)
        XCTAssertNotNil(media, "a photo or video alone is worth asking about")
        let unfilmed = LiveRemoval.prompt(for: match(sets: [game(11, 5, end: 100)]), name: "Table tennis", mediaCount: 0)
        XCTAssertEqual(unfilmed?.title, "Remove this match?")
        XCTAssertEqual(unfilmed?.confirm, "Remove this match")
        XCTAssertEqual(unfilmed?.message, "Its games are deleted from this session. Its photos and videos stay, under General.")
    }

    func testRemovingARecordedMatchOrDrillSaysTheSplitRalliesAndTagsGoAndTheVideoStays() {
        let m = LiveRemoval.prompt(for: match(log: recordedLog()), name: "Table tennis", mediaCount: 0)
        XCTAssertEqual(m?.message, "Its games are deleted from this session, with its recording’s split, rallies and tags. "
                       + "The video stays in your Photos library, and its clips stay in this session, under General.")
        let d = LiveRemoval.prompt(for: drill(log: recordedLog()), name: "Forehand loop", mediaCount: 0)
        XCTAssertEqual(d?.title, "Remove this drill?")
        XCTAssertTrue(d?.message.hasPrefix("Its blocks are deleted from this session, with its recording’s block marks, rallies and tags.") == true,
                      d?.message ?? "")
        for p in [m, d, LiveRemoval.prompt(for: lift(sets: 1), name: "Bench", mediaCount: 0)] {
            XCTAssertFalse((p?.message ?? "").contains("—"), "no em dash in UI strings")
        }
    }

    // MARK: - F2 finish

    func testFinishWithACompletedSetOpensTheSummary() {
        XCTAssertEqual(LiveFinish.decide(exercises: [lift(sets: 1)], completedSets: 1, mediaCount: 3), .summary)
    }

    func testFinishWithNothingWorthKeepingDiscardsSilently() {
        XCTAssertEqual(LiveFinish.decide(exercises: [], completedSets: 0, mediaCount: 0), .discard)
        XCTAssertEqual(LiveFinish.decide(exercises: [lift(), match()], completedSets: 0, mediaCount: 0), .discard,
                       "exercises with no sets, no media, no recording")
        XCTAssertFalse(LiveFinish.intentSaves(.discard))
    }

    func testFinishWithARecordingButNoGamesAsksAndSaysWhatDiscardDeletes() {
        let d = LiveFinish.decide(exercises: [match(log: recordedLog())], completedSets: 0, mediaCount: 2)
        XCTAssertEqual(d, .ask(lost: "Discard deletes 1 recording with its split, rallies and tags and 2 photos and videos "
                               + "from this session. Videos stay in your Photos library."))
        XCTAssertTrue(LiveFinish.intentSaves(d), "the intent / link saves instead of deleting")
    }

    func testFinishAsksForMediaOnlyAndForSetsWithoutACompletedStamp() {
        XCTAssertEqual(LiveFinish.decide(exercises: [], completedSets: 0, mediaCount: 1),
                       .ask(lost: "Discard deletes 1 photo or video from this session. Videos stay in your Photos library."))
        XCTAssertEqual(LiveFinish.decide(exercises: [lift(sets: 2)], completedSets: 0, mediaCount: 0),
                       .ask(lost: "Discard deletes 2 logged sets from this session."))
        XCTAssertEqual(LiveFinish.lostLine(sets: 1, recordings: 2, media: 1),
                       "Discard deletes 1 logged set, 2 recordings with their splits, rallies and tags and 1 photo or video "
                       + "from this session. Videos stay in your Photos library.")
        XCTAssertTrue(LiveFinish.intentSaves(.summary))
    }

    // MARK: - F4 finish while a cover is open

    func testTheFinishIntentRefusesWhileARacketCoverIsOpen() {
        XCTAssertNil(LiveFinish.refusal(openCover: nil))
        XCTAssertEqual(LiveFinish.refusal(openCover: .recording)?.message,
                       "This screen is still recording. Stop it here first, then finish the session. Nothing was deleted.")
        XCTAssertEqual(LiveFinish.refusal(openCover: .drill)?.title, "Session not finished")
        XCTAssertEqual(LiveFinish.refusal(openCover: .game)?.message,
                       "This match is still open. End it here first, then finish the session. Nothing was deleted.")
    }

    @MainActor
    func testTheOpenCoverRegistry() {
        let covers = RacketLiveCovers()
        let a = UUID(), b = UUID()
        XCTAssertFalse(covers.refuseFinishIfOpen(), "nothing open: the finish goes ahead")
        covers.opened(a, .game)
        covers.closed(a)
        covers.opened(b, .recording)
        XCTAssertTrue(covers.isOpen(b))
        XCTAssertFalse(covers.isOpen(a))
        XCTAssertTrue(covers.refuseFinishIfOpen())
        XCTAssertEqual(covers.refusal, LiveFinish.refusal(openCover: .recording))
        // A late disappear of an older cover doesn't clear the newer one.
        covers.closed(a)
        XCTAssertEqual(covers.openKind, .recording)
        covers.closed(b)
        XCTAssertNil(covers.openKind)
        XCTAssertNil(covers.refusal, "the refusal goes with its cover")
    }

    // MARK: - F1 one recording per entry

    func testRecordEverythingIsBlockedOnceSomethingWasRecorded() {
        XCTAssertNil(RacketRecordingGuard.recordEverythingBlock(match()))
        XCTAssertNil(RacketRecordingGuard.recordEverythingBlock(match(log: RacketRecordingLog(startedAt: t0))),
                     "a log where nothing was recorded may be replaced")
        XCTAssertEqual(RacketRecordingGuard.recordEverythingBlock(match(log: recordedLog())),
                       "This match already has a recording. A second one isn’t supported yet.")
        var partsOnly = RacketRecordingLog(startedAt: t0)
        partsOnly.assets = [.init(localIdentifier: "a", startSec: 0, durationSec: 60)]
        XCTAssertNotNil(RacketRecordingGuard.recordEverythingBlock(match(log: partsOnly)), "a saved part counts")
        XCTAssertNotNil(RacketRecordingGuard.recordEverythingBlock(match(log: recordedLog(mode: .byUnit))),
                        "switching a game-by-game match to record everything")
    }

    func testGameByGameIsBlockedOverARecordEverythingRecording() {
        XCTAssertNil(RacketRecordingGuard.gameByGameBlock(match()))
        XCTAssertNil(RacketRecordingGuard.gameByGameBlock(match(log: RacketRecordingLog(startedAt: t0))),
                     "nothing recorded yet")
        XCTAssertNil(RacketRecordingGuard.gameByGameBlock(match(log: recordedLog(mode: .byUnit))),
                     "its own game-by-game log is continued")
        XCTAssertEqual(RacketRecordingGuard.gameByGameBlock(match(log: recordedLog())),
                       "This match already has a recording. A second one isn’t supported yet.")
    }

    func testDrillStartContinuesItsOwnLogAndBlocksAnotherMode() {
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(), recording: .everything), .fresh)
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(log: recordedLog()), recording: .everything), .continueLog)
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(log: recordedLog(mode: .byUnit)), recording: .byUnit), .continueLog)
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(log: recordedLog(mode: .byUnit)), recording: .everything),
                       .blocked("This drill already has a recording. A second one isn’t supported yet."))
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(log: recordedLog()), recording: .byUnit),
                       .blocked(RacketRecordingGuard.drillReason))
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(log: RacketRecordingLog(startedAt: t0)), recording: .byUnit), .fresh,
                       "nothing recorded in the other mode")
        XCTAssertEqual(RacketRecordingGuard.drillStart(drill(log: recordedLog()), recording: .off), .fresh, "not filming")
    }

    func testARecordedLogIsNeverReplacedByAnotherRecording() {
        let old = recordedLog()
        var later = RacketRecordingLog(startedAt: t0.addingTimeInterval(3600))
        later.runs = [.init(startSec: 0, endSec: nil, endReasonRaw: nil)]
        XCTAssertFalse(RacketRecordingGuard.mayReplace(old, with: later))
        var same = old
        same.marks = [.init(kindRaw: "moment", index: nil, startSec: 10, endSec: nil)]
        XCTAssertTrue(RacketRecordingGuard.mayReplace(old, with: same), "the same recording, updated")
        XCTAssertTrue(RacketRecordingGuard.mayReplace(nil, with: later))
        XCTAssertTrue(RacketRecordingGuard.mayReplace(RacketRecordingLog(startedAt: t0), with: later), "nothing was recorded")
    }

    /// "Continue drill" on a record-everything drill continues its log: the earlier blocks' marks, runs and parts stay,
    /// the new block is added after them, and the drill's video still maps every block to its own logged block.
    func testAContinuedRecordEverythingDrillKeepsItsEarlierBlockMarks() {
        var old = RacketRecordingLog(startedAt: t0)
        old.baseSetIndex = 0
        old.runs = [.init(startSec: 0, endSec: 700, endReasonRaw: nil)]
        old.assets = [.init(localIdentifier: "p1", startSec: 0, durationSec: 700)]
        old.marks = [.init(kindRaw: "block", index: 0, startSec: 10, endSec: 310),
                     .init(kindRaw: "rest", index: 0, startSec: 310, endSec: 370),
                     .init(kindRaw: "block", index: 1, startSec: 370, endSec: 670)]
        old.endedAt = t0.addingTimeInterval(700)
        old.rallies = [RacketRally(startSec: 20, endSec: 28, winner: .us)]
        let plan = RacketDrillPlan(blocks: 3, blockSec: 60, restSec: 30, autoStart: true, countdownSec: 5, recording: .everything)
        let reopen = t0.addingTimeInterval(1000)
        var m = RacketRecordingMachine(kind: .drill(plan), recording: .everything, stillPlayingMinutes: nil, now: reopen)
        m.startingBlock = 2
        m.baseSetIndex = 0
        m.continueLog(old)
        XCTAssertEqual(m.log?.startedAt, old.startedAt, "the same recording")
        m.start(now: reopen)
        XCTAssertEqual(m.phase, .countdown(block: 2, endsAt: reopen.addingTimeInterval(5)))
        XCTAssertEqual(m.tick(now: reopen.addingTimeInterval(5)), [.startCapture])
        let effects = m.tick(now: reopen.addingTimeInterval(65))
        XCTAssertTrue(effects.contains(.logBlock(index: 2, durationSec: 60)), "\(effects)")
        m.end(now: reopen.addingTimeInterval(70))
        let log = try! XCTUnwrap(m.log)
        XCTAssertEqual(Array(log.marks.prefix(3)), old.marks, "the earlier block marks survive unchanged")
        XCTAssertEqual(log.blockMarks.map(\.index), [0, 1, 2])
        XCTAssertEqual(log.runs.first, old.runs.first)
        XCTAssertEqual(log.runs.count, 2, "a new run for the new block")
        XCTAssertEqual(log.assets, old.assets)
        XCTAssertEqual(log.rallies, old.rallies, "tags kept")
        XCTAssertTrue(RacketRecordingGuard.mayReplace(old, with: log), "the host saves it over the old one (same recording)")
        XCTAssertEqual(RacketSplitProposal.drillParts(log: log).filter { $0.kind == .drillBlock }.map(\.setIndex), [0, 1, 2])
    }

    func testContinueLogOnlyContinuesTheSameMode() {
        let plan = RacketDrillPlan(recording: .everything)
        var m = RacketRecordingMachine(kind: .drill(plan), recording: .everything, stillPlayingMinutes: nil, now: t0)
        m.continueLog(recordedLog(mode: .byUnit))
        XCTAssertNil(m.log, "a block-by-block log isn't continued by a record-everything drill")
        var match = RacketRecordingMachine(kind: .match, recording: .everything, stillPlayingMinutes: nil, now: t0)
        match.continueLog(recordedLog())
        XCTAssertNil(match.log, "record everything on a match never continues (a second recording is blocked)")
        var byUnit = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: t0)
        byUnit.continueLog(recordedLog(mode: .byUnit))
        XCTAssertNotNil(byUnit.log, "game by game still continues")
    }

    // MARK: - F14 a recording left open by a crash

    private func crashed() -> RacketRecordingLog {
        var l = RacketRecordingLog(startedAt: t0)
        l.baseSetIndex = 0
        l.runs = [.init(startSec: 0, endSec: 600, endReasonRaw: "appLeft"), .init(startSec: 650, endSec: nil, endReasonRaw: nil)]
        l.assets = [.init(localIdentifier: "p1", startSec: 0, durationSec: 600),
                    .init(localIdentifier: "p2", startSec: 650, durationSec: 600),
                    .init(localIdentifier: "p3", startSec: 1250, durationSec: 300)]
        l.marks = [.init(kindRaw: "newGame", index: nil, startSec: 900, endSec: nil),
                   .init(kindRaw: "interval", index: nil, startSec: 1400, endSec: nil)]
        return l
    }

    func testAnOpenRunIsClosedAtTheLastSavedPartAndTheTimeStopsGrowing() throws {
        let fixed = try XCTUnwrap(RacketRecordingRecovery.recovered(crashed()))
        XCTAssertEqual(fixed.runs.map(\.endSec), [600, 1550], "closed at the end of the last saved part")
        XCTAssertEqual(fixed.endedAt, t0.addingTimeInterval(1550))
        XCTAssertEqual(fixed.recordedSec(now: t0.addingTimeInterval(99_999)), 1500, "no longer counts to now")
        XCTAssertEqual(fixed.recordedSec(now: fixed.endedAt ?? .now), 1500)
        XCTAssertNil(fixed.marks[0].endSec, "a single-time mark stays a single time")
        XCTAssertEqual(fixed.marks[1].endSec, 1550, "an open range mark closes with the recording")
        XCTAssertEqual(fixed.assets, crashed().assets, "parts untouched")
        XCTAssertNil(RacketRecordingRecovery.recovered(fixed), "nothing more to do")
    }

    func testAnOpenRunWithNoSavedPartClosesAtItsStart() throws {
        var l = crashed()
        l.assets = [l.assets[0]]
        let fixed = try XCTUnwrap(RacketRecordingRecovery.recovered(l))
        XCTAssertEqual(fixed.runs.map(\.endSec), [600, 650], "nothing of the second run was saved")
        XCTAssertEqual(fixed.endedAt, t0.addingTimeInterval(650))
    }

    func testAnEarlierOpenRunEndsBeforeTheNextOne() throws {
        var l = RacketRecordingLog(startedAt: t0)
        l.modeRaw = RacketRecordingMode.byUnit.rawValue
        l.runs = [.init(startSec: 0, endSec: nil, endReasonRaw: nil), .init(startSec: 300, endSec: 500, endReasonRaw: nil)]
        l.assets = [.init(localIdentifier: "a", startSec: 0, durationSec: 280), .init(localIdentifier: "b", startSec: 300, durationSec: 200)]
        l.marks = [.init(kindRaw: "game", index: 0, startSec: 0, endSec: nil)]
        let fixed = try XCTUnwrap(RacketRecordingRecovery.recovered(l))
        XCTAssertEqual(fixed.runs.map(\.endSec), [280, 500])
        XCTAssertNil(fixed.endedAt, "a game-by-game log is continued later; its cover reads endedAt as now")
        XCTAssertEqual(fixed.marks[0].endSec, 500)
    }

    func testAClosedRecordingIsLeftAlone() {
        XCTAssertNil(RacketRecordingRecovery.recovered(recordedLog()))
        var betweenGames = recordedLog(mode: .byUnit)
        betweenGames.endedAt = nil
        XCTAssertNil(RacketRecordingRecovery.recovered(betweenGames), "game by game, closed between games")
        XCTAssertNil(RacketRecordingRecovery.recovered(RacketRecordingLog(startedAt: t0)), "nothing recorded")
    }

    func testRecoveryNeverTouchesAnEntryThatIsRecordingNow() throws {
        let live = match(log: crashed())
        let killed = match(log: crashed())
        let out = try XCTUnwrap(RacketRecordingRecovery.recoverAll([live, killed, lift(sets: 1)], live: [live.id]))
        XCTAssertEqual(out[0].racketRecordingLog, crashed(), "the open cover's recording is untouched")
        XCTAssertEqual(out[1].racketRecordingLog?.runs.last?.endSec, 1550)
        XCTAssertNil(RacketRecordingRecovery.recoverAll([live], live: [live.id]))
    }

    // MARK: - F3 the drawer's delete

    /// The review's first case: a stray game logged before the recording is deleted in the drawer. The base moves
    /// with it, so the next split links the recording's games and adds no duplicate "Score unconfirmed" game.
    func testDeletingAGameBeforeTheRecordingMovesTheBase() throws {
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = 1
        log.runs = [.init(startSec: 0, endSec: 800, endReasonRaw: nil)]
        log.endedAt = t0.addingTimeInterval(800)
        let sets = [game(9, 11, end: -300, duration: 6), game(11, 7, end: 402), game(8, 11, end: 795)]
        let ex = match(sets: sets, log: log)
        XCTAssertNil(RacketLiveDrawer.deleteBlock(ex, index: 0))
        let r = try XCTUnwrap(RacketLiveDrawer.remove(ex, at: 0))
        XCTAssertEqual(r.sets, [sets[1], sets[2]])
        XCTAssertEqual(r.log?.baseSetIndex, 0)
        XCTAssertEqual(r.remap, [1: 0, 2: 1])
        let parts = [RacketVideoPart(kind: .game, startSec: 0, endSec: 400), RacketVideoPart(kind: .game, startSec: 400, endSec: 800)]
        let split = RacketSplitAssign.apply(parts: parts, sets: r.sets, base: r.log?.baseIndex ?? 0, startedAt: t0)
        XCTAssertEqual(split.added, 0, "no duplicate game")
        XCTAssertEqual(split.parts.map(\.setIndex), [0, 1])
        // What the drawer did before: the base left at 1 makes the next split add a "Score unconfirmed" duplicate.
        let stale = RacketSplitAssign.apply(parts: parts, sets: r.sets, base: 1, startedAt: t0)
        XCTAssertEqual(stale.added, 1)
    }

    /// The review's second case: a game inside the recording (not split yet) is deleted; the base stays.
    func testDeletingAGameInsideTheRecordingKeepsTheBase() throws {
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = 1
        log.runs = [.init(startSec: 0, endSec: 1200, endReasonRaw: nil)]
        let sets = [game(9, 11, end: -300), game(11, 7, end: 400), game(5, 11, end: 800), game(11, 9, end: 1190)]
        let r = try XCTUnwrap(RacketLiveDrawer.remove(match(sets: sets, log: log), at: 2))
        XCTAssertEqual(r.sets, [sets[0], sets[1], sets[3]])
        XCTAssertEqual(r.log?.baseSetIndex, 1)
        XCTAssertEqual(r.remap, [0: 0, 1: 1, 3: 2], "the removed game's photos stay on the match with no game")
    }

    func testAGameWithVideoCantBeSwipedAwayAndSaysWhy() {
        let ex = match(sets: RacketVideoSeed.strayGameMatch(recordingStart: t0).sets,
                       log: RacketVideoSeed.strayGameMatch(recordingStart: t0).log)
        XCTAssertNil(RacketLiveDrawer.deleteBlock(ex, index: 0), "the stray game has no video")
        for i in 1...3 {
            XCTAssertEqual(RacketLiveDrawer.deleteBlock(ex, index: i), "Has video. Remove it from Edit match after the session.")
            XCTAssertNil(RacketLiveDrawer.remove(ex, at: i))
        }
        // Game by game: each game has its own clip (a game mark).
        var gbg = RacketRecordingLog(startedAt: t0)
        gbg.modeRaw = RacketRecordingMode.byUnit.rawValue
        gbg.marks = [.init(kindRaw: "game", index: 0, startSec: 0, endSec: 120)]
        XCTAssertNotNil(RacketLiveDrawer.deleteBlock(match(sets: [game(11, 3, end: 120), game(11, 4, end: 400)], log: gbg), index: 0))
        XCTAssertNil(RacketLiveDrawer.deleteBlock(match(sets: [game(11, 3, end: 120), game(11, 4, end: 400)], log: gbg), index: 1))
    }

    /// The user's real case, live: the stray game goes; the recording's three games keep their video and tags.
    func testTheRealCaseLiveRemovesTheStrayGameLikeEditMatch() throws {
        let seed = RacketVideoSeed.strayGameMatch(recordingStart: t0)
        let ex = match(sets: seed.sets, log: seed.log)
        let r = try XCTUnwrap(RacketLiveDrawer.remove(ex, at: 0))
        let d = RacketMatchEditor.draft(from: ex)
        let viaEditor = RacketMatchEditor.commit(RacketMatchEditor.remove(d, game: d.games[0].id), log: ex.racketRecordingLog)
        XCTAssertEqual(r.sets, viaEditor.sets)
        XCTAssertEqual(r.log, viaEditor.log, "exactly what Edit match saves")
        XCTAssertEqual(r.log?.baseSetIndex, 0)
        XCTAssertEqual(r.log?.split?.parts.compactMap(\.setIndex), [0, 1, 2])
        XCTAssertEqual(r.log?.rallies, seed.log.rallies, "tags intact")
        XCTAssertEqual(r.sets.count, 3)
    }

    func testAnUnlinkedGameInsideASplitRecordingRenumbersTheLinksAfterIt() throws {
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = 0
        log.runs = [.init(startSec: 0, endSec: 600, endReasonRaw: nil)]
        log.endedAt = t0.addingTimeInterval(600)
        var a = RacketVideoPart(kind: .game, startSec: 0, endSec: 300); a.setIndex = 0
        var b = RacketVideoPart(kind: .game, startSec: 300, endSec: 600); b.setIndex = 2
        log.split = RacketSplit(parts: [a, b], appliedAt: t0.addingTimeInterval(700))
        let sets = [game(11, 7, end: 300, duration: 290), game(nil, nil, end: 310), game(9, 11, end: 600, duration: 290)]
        let ex = match(sets: sets, log: log)
        XCTAssertNil(RacketLiveDrawer.deleteBlock(ex, index: 1), "the extra game has no video")
        let r = try XCTUnwrap(RacketLiveDrawer.remove(ex, at: 1))
        XCTAssertEqual(r.sets.map(\.scoreFor), [11, 9])
        XCTAssertEqual(r.log?.split?.parts.map(\.setIndex), [0, 1], "the second video now points at the second game")
    }

    func testTheOnlyGameWithNoVideoCanGoInALiveMatch() throws {
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = 1
        log.runs = [.init(startSec: 0, endSec: nil, endReasonRaw: nil)]
        let r = try XCTUnwrap(RacketLiveDrawer.remove(match(sets: [game(9, 11, end: -60)], log: log), at: 0))
        XCTAssertEqual(r.sets, [])
        XCTAssertEqual(r.log?.baseSetIndex, 0)
        XCTAssertEqual(r.log?.runs, log.runs)
        XCTAssertEqual(try XCTUnwrap(RacketLiveDrawer.remove(match(sets: [game(9, 11, end: 0)]), at: 0)).sets, [], "no recording")
    }

    func testDrillBlocksWithVideoStayAndLaterMarksMoveUp() throws {
        // Block 0 logged by hand before filming; blocks 1 and 2 recorded (marks 1, 2, a rest after 1); block 3 by hand.
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = 0
        log.runs = [.init(startSec: 0, endSec: 700, endReasonRaw: nil)]
        log.marks = [.init(kindRaw: "block", index: 1, startSec: 10, endSec: 310),
                     .init(kindRaw: "rest", index: 1, startSec: 310, endSec: 370),
                     .init(kindRaw: "block", index: 2, startSec: 370, endSec: 670)]
        log.endedAt = t0.addingTimeInterval(700)
        let sets = (0..<4).map { SetLog(completedAt: t0.addingTimeInterval(Double($0) * 300), durationSec: 300) }
        let ex = drill(sets: sets, log: log)
        XCTAssertNil(RacketLiveDrawer.deleteBlock(ex, index: 0))
        XCTAssertEqual(RacketLiveDrawer.deleteBlock(ex, index: 1), "Has video, so it stays with its recording.")
        XCTAssertNotNil(RacketLiveDrawer.deleteBlock(ex, index: 2))
        XCTAssertNil(RacketLiveDrawer.deleteBlock(ex, index: 3))
        let r = try XCTUnwrap(RacketLiveDrawer.remove(ex, at: 0))
        XCTAssertEqual(r.sets.count, 3)
        XCTAssertEqual(r.log?.marks.map(\.index), [0, 0, 1], "every mark still points at its own block")
        XCTAssertEqual(r.remap, [1: 0, 2: 1, 3: 2])
        let parts = RacketSplitProposal.drillParts(log: try XCTUnwrap(r.log)).filter { $0.kind == .drillBlock }
        XCTAssertEqual(parts.map(\.setIndex), [0, 1])
        XCTAssertEqual(parts.map(\.startSec), [10, 370], "block 1's video is now set 0's")
        let last = try XCTUnwrap(RacketLiveDrawer.remove(ex, at: 3))
        XCTAssertEqual(last.log?.marks, log.marks, "a later block leaves the marks as they were")
    }

    func testNonRacketExercisesKeepThePlainDelete() {
        XCTAssertNil(RacketLiveDrawer.deleteBlock(lift(sets: 2), index: 0))
        XCTAssertNil(RacketLiveDrawer.remove(lift(sets: 2), at: 0), "the drawer's own remove + media reindex")
    }
}
