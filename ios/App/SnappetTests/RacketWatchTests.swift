import XCTest
@testable import Snappet

/// Unit tests for racket on the Apple Watch (prompt 245, issue #438 step 2), all pure, no Watch: the phone ↔ Watch
/// wire (`Shared/RacketWatchMessage.swift`), the point-by-point tally and undo (`Shared/RacketLiveScore.swift`), the
/// rings per surface, the Watch's optimistic tap, haptic cues, and the phone's mapping of Watch taps onto the
/// record-everything machine and the game-by-game Watch match (`RacketWatchBridge.swift`).
final class RacketWatchTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let sid = UUID()

    private let tt = RacketLiveRules(kind: .rally, pointsTo: 11)
    private let tennis = RacketLiveRules(kind: .sets, pointsTo: 6)

    private func score(_ rules: RacketLiveRules, _ pattern: String) -> RacketLiveScore {
        RacketLiveScore(rules: rules, points: pattern.map { $0 == "u" ? .us : .them })
    }

    private func state(_ surface: RacketWatchState.Surface, revision: Int = 1,
                       still: RacketWatchState.StillPlaying? = nil,
                       notice: RacketWatchState.Notice? = nil) -> RacketWatchState {
        RacketWatchState(sessionID: sid, revision: revision, sport: "Table tennis", unitNoun: "game", sideUs: "You",
                         sideThem: "Alex", note: "Tap who won each point.", surface: surface, stillPlaying: still,
                         notice: notice)
    }

    private func scoring(_ s: RacketLiveScore, unit: Int = 1) -> RacketWatchState.Surface {
        .scoring(.init(unitNumber: unit, score: s, clock: .init(base: 0, asOf: t0, running: true), matchLine: nil))
    }

    private func drillMachine(blocks: Int = 3, blockSec: Int = 120, restSec: Int = 60, autoStart: Bool = true,
                              still: Int? = 60) -> RacketRecordingMachine {
        let plan = RacketDrillPlan(blocks: blocks, blockSec: blockSec, restSec: restSec, autoStart: autoStart,
                                   countdownSec: 5, recording: .everything)
        return RacketRecordingMachine(kind: .drill(plan), stillPlayingMinutes: still, now: t0)
    }

    private func matchMachine(still: Int? = 60) -> RacketRecordingMachine {
        RacketRecordingMachine(kind: .match, stillPlayingMinutes: still, now: t0)
    }

    private let ctx = RacketWatchContext(sessionID: UUID(), sport: .tableTennis, sideUs: "You", sideThem: "Alex",
                                         unitNumber: 1)

    private func racketMatch(_ sport: RacketSport = .tableTennis, opponent: String? = "Alex Chen", partner: String? = nil,
                             games: [SetLog] = [], bestOf: Int? = 5) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(sport), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: games, displayName: RacketStats.matchActivityName(sport),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = sport.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = opponent
        ex.partner = partner
        ex.racketBestOf = bestOf
        return ex
    }

    // MARK: - Wire (Shared/RacketWatchMessage.swift)

    func testEveryStateSurfaceRoundTripsThroughThePropertyListPayload() {
        let surfaces: [RacketWatchState.Surface] = [
            .start(.init(title: "Start block 1?", cameraReady: true, footnote: "f")),
            scoring(score(tt, "uut")),
            .marks(.init(clock: .init(base: 12, asOf: at(3), running: true), unitNumber: 2, score: score(tennis, "uuuu"),
                         matchLine: "Games 1–0", markCount: 3)),
            .countdown(.init(block: 0, blocks: 3, endsAt: at(5), totalSec: 5)),
            .block(.init(index: 1, blocks: 3, startedAt: at(10), totalSec: 120, recording: true)),
            .rest(.init(after: 1, blocks: 3, endsAt: nil, remainingSec: 31, totalSec: 60, paused: true, done: false,
                        autoStart: false)),
            .matchBreak(.init(unitNumber: 1, unitScore: "11–9", endsAt: at(60), remainingSec: 0, totalSec: 60, paused: false)),
            .ended(.init(title: "Drill done", line: "1 recording · 3 block parts")),
        ]
        for s in surfaces {
            let st = state(s, still: .init(askedAt: at(1), minutes: 45, answerWindowSec: 120),
                           notice: .init(reason: .tooHot, canResume: false, savedUpToSec: 1864))
            let payload = RacketWatchMessage.state(st).payload
            XCTAssertEqual(RacketWatchMessage(payload: payload), .state(st), s.kind)
        }
    }

    func testCommandAndClearRoundTripAndForeignPayloadsAreIgnored() {
        let c = RacketWatchCommandEnvelope(sessionID: sid, command: .pointThem, at: at(2))
        XCTAssertEqual(RacketWatchMessage(payload: RacketWatchMessage.command(c).payload), .command(c))
        XCTAssertEqual(RacketWatchMessage(payload: RacketWatchMessage.clear(sessionID: sid).payload), .clear(sessionID: sid))
        // The other relays' messages aren't ours, and ours aren't theirs.
        XCTAssertNil(RacketWatchMessage(payload: LiveWorkoutMessage.pause.payload))
        XCTAssertNil(RacketWatchMessage(payload: ["householdKind": "toggle"]))
        XCTAssertNil(LiveWorkoutMessage(payload: RacketWatchMessage.command(c).payload))
        XCTAssertNil(HouseholdWatchMessage(payload: RacketWatchMessage.clear(sessionID: sid).payload))
        // Malformed data drops the message.
        XCTAssertNil(RacketWatchMessage(payload: ["racketKind": "state", "data": Data("{}".utf8)]))
        XCTAssertNil(RacketWatchMessage(payload: ["racketKind": "clear", "session": "nope"]))
    }

    func testEveryCommandSurvivesTheWire() {
        for cmd in RacketWatchCommand.allCases {
            let c = RacketWatchCommandEnvelope(sessionID: sid, command: cmd, at: at(1))
            XCTAssertEqual(RacketWatchMessage(payload: RacketWatchMessage.command(c).payload), .command(c), cmd.rawValue)
        }
    }

    // MARK: - Live score: rally games

    func testRallyGameGoesToElevenWinByTwo() {
        var s = score(tt, "uuuuuuuuuu" + "tttttttttt")   // 10–10
        XCTAssertEqual(s.display, "10 – 10")
        XCTAssertFalse(s.isFinished)
        s.point(.us)
        XCTAssertFalse(s.isFinished, "11–10 isn't won")
        s.point(.us)
        XCTAssertEqual(s.result, RacketLiveUnitResult(scoreFor: 12, scoreAgainst: 10))
        XCTAssertFalse(s.point(.them), "No points after the game is decided")
        XCTAssertEqual(s.display, "12 – 10")
        XCTAssertEqual(s.header(unitNumber: 3), "Game 3")
    }

    func testUndoReopensAFinishedGame() {
        var s = score(tt, String(repeating: "u", count: 11))
        XCTAssertEqual(s.result?.label, "11–0")
        XCTAssertTrue(s.undo())
        XCTAssertNil(s.result)
        XCTAssertEqual(s.display, "10 – 0")
        var empty = RacketLiveScore(rules: tt)
        XCTAssertFalse(empty.undo(), "Nothing to undo")
    }

    func testBadmintonCapWinsAtThirty() {
        let bd = RacketLiveRules(kind: .rally, pointsTo: 21, cap: 30)
        let s = score(bd, String(repeating: "ut", count: 29) + "u")   // 30–29
        XCTAssertEqual(s.result, RacketLiveUnitResult(scoreFor: 30, scoreAgainst: 29))
    }

    func testReplayingPointsPastTheEndKeepsTheResult() {
        let s = score(tt, String(repeating: "t", count: 13))
        XCTAssertEqual(s.points.count, 11, "Points after the game ended are dropped")
        XCTAssertEqual(s.result?.won, false)
    }

    // MARK: - Live score: tennis / padel sets

    func testTennisPointsDeuceAndAdvantage() {
        XCTAssertEqual(score(tennis, "").display, "0 – 0")
        XCTAssertEqual(score(tennis, "u").display, "15 – 0")
        XCTAssertEqual(score(tennis, "uut").display, "30 – 15")
        XCTAssertEqual(score(tennis, "uuuttt").display, "40 – 40")
        XCTAssertEqual(score(tennis, "uuuttt" + "u").display, "Ad – 40")
        XCTAssertEqual(score(tennis, "uuuttt" + "ut" + "t").display, "40 – Ad")
        let game = score(tennis, "uuuttt" + "uu")
        XCTAssertEqual(game.tally.gamesFor, 1)
        XCTAssertEqual(game.display, "0 – 0", "A new game starts at love")
        XCTAssertEqual(game.header(unitNumber: 1), "Set 1 · Games 1–0")
    }

    func testTennisSetSixFourAndSevenFive() {
        let g = "uuuu", l = "tttt"
        let sixFour = score(tennis, String(repeating: g + l, count: 4) + g + g)
        XCTAssertEqual(sixFour.result, RacketLiveUnitResult(scoreFor: 6, scoreAgainst: 4))
        let sevenFive = score(tennis, String(repeating: g + l, count: 5) + g + g)
        XCTAssertEqual(sevenFive.result, RacketLiveUnitResult(scoreFor: 7, scoreAgainst: 5))
    }

    func testTennisTiebreakAtSixAll() {
        let g = "uuuu", l = "tttt"
        var s = score(tennis, String(repeating: g + l, count: 6))   // 6–6
        XCTAssertTrue(s.tally.inTiebreak)
        XCTAssertEqual(s.header(unitNumber: 2), "Set 2 · Tiebreak")
        for p in "uuuuuu" + "ttttt" { s.point(p == "u" ? .us : .them) }   // 6–5 in the tiebreak
        XCTAssertEqual(s.display, "6 – 5")
        s.point(.us)                                                         // 7–5
        XCTAssertEqual(s.result, RacketLiveUnitResult(scoreFor: 7, scoreAgainst: 6, tiebreakFor: 7, tiebreakAgainst: 5))
        XCTAssertEqual(s.header(unitNumber: 2), "Set 2 · Games 7–6")
    }

    func testSuperTiebreakToTen() {
        let stb = RacketLiveRules(kind: .sets, pointsTo: 6, superTiebreak: true)
        let s = score(stb, String(repeating: "u", count: 9) + String(repeating: "t", count: 9) + "uu")
        XCTAssertEqual(s.result, RacketLiveUnitResult(scoreFor: 11, scoreAgainst: 9, superTiebreak: true))
        XCTAssertEqual(score(stb, "uut").display, "2 – 1")
        XCTAssertEqual(score(stb, "u").header(unitNumber: 3), "Match tiebreak")
    }

    func testRulesFollowTheMatchFormat() {
        XCTAssertEqual(RacketLiveRules(format: .defaults(for: .tableTennis), unitIndex: 0), tt)
        XCTAssertEqual(RacketLiveRules(format: .defaults(for: .badminton), unitIndex: 0).cap, 30)
        XCTAssertEqual(RacketLiveRules(format: .defaults(for: .tennis), unitIndex: 0), tennis)
        let stb = RacketFormat(sport: .padel, bestOf: 3, superTiebreak: true)
        XCTAssertFalse(RacketLiveRules(format: stb, unitIndex: 1).superTiebreak)
        XCTAssertTrue(RacketLiveRules(format: stb, unitIndex: 2).superTiebreak, "The decider is a match tiebreak")
    }

    func testEndedEarlyLogsWhereTheTallyStands() {
        XCTAssertEqual(score(tt, "uuut").provisionalResult, .init(scoreFor: 3, scoreAgainst: 1))
        XCTAssertEqual(score(tennis, "uuuu" + "tt").provisionalResult, .init(scoreFor: 1, scoreAgainst: 0),
                       "A set ended early logs its games")
    }

    // MARK: - Rings (review5: Watch timers had no ring)

    func testRingsUseThePhaseTones() {
        let block = RacketWatchState.Surface.block(.init(index: 0, blocks: 3, startedAt: t0, totalSec: 120, recording: true))
        let b = block.ring(now: at(30))
        XCTAssertEqual(b?.tone, .work)
        XCTAssertEqual(b?.seconds, 90)
        XCTAssertEqual(b?.progress ?? 0, 0.75, accuracy: 0.001)

        let rest = RacketWatchState.Surface.rest(.init(after: 0, blocks: 3, endsAt: at(45), remainingSec: 0, totalSec: 60,
                                                       paused: false, done: false, autoStart: true))
        XCTAssertEqual(rest.ring(now: t0)?.tone, .rest)
        XCTAssertEqual(rest.ring(now: t0)?.seconds, 45)

        let paused = RacketWatchState.Surface.rest(.init(after: 0, blocks: 3, endsAt: nil, remainingSec: 20, totalSec: 60,
                                                         paused: true, done: false, autoStart: true))
        XCTAssertEqual(paused.ring(now: at(999))?.tone, .restPaused, "Paused is grey at reduced opacity")
        XCTAssertEqual(paused.ring(now: at(999))?.seconds, 20, "A paused ring doesn't run")

        let brk = RacketWatchState.Surface.matchBreak(.init(unitNumber: 1, unitScore: "11–9", endsAt: at(60), remainingSec: 0,
                                                            totalSec: 120, paused: false))
        XCTAssertEqual(brk.ring(now: t0)?.tone, .rest, "Break is grey")
        XCTAssertEqual(brk.ring(now: t0)?.word, "Break")

        XCTAssertEqual(RacketWatchState.Surface.ended(.init(title: "Drill done", line: "")).ring(now: t0)?.tone, .done)
        let cd = RacketWatchState.Surface.countdown(.init(block: 1, blocks: 3, endsAt: at(3), totalSec: 5))
        XCTAssertEqual(cd.ring(now: t0)?.word, "Block 2 starts")
        XCTAssertNil(scoring(score(tt, "")).ring(now: t0), "Scoring has no timer ring")
    }

    func testClocksRunOnTheWatchBetweenSnapshots() {
        let c = RacketWatchClock(base: 100, asOf: t0, running: true)
        XCTAssertEqual(c.seconds(now: at(20)), 120)
        XCTAssertEqual(RacketWatchClock(base: 100, asOf: t0, running: false).seconds(now: at(20)), 100)
    }

    // MARK: - Watch-side rules

    func testTheWatchShowsAScoreTapAtOnce() {
        let s = state(scoring(score(tt, "u")), still: .init(askedAt: t0, minutes: 30, answerWindowSec: 120))
        let shown = s.applyingOptimistically(.pointThem)
        guard case .scoring(let sc)? = shown?.surface else { return XCTFail("Still scoring") }
        XCTAssertEqual(sc.score.display, "1 – 1")
        XCTAssertNil(shown?.stillPlaying, "A tap answers Still playing?")
        XCTAssertEqual(shown?.revision, s.revision, "The phone's next snapshot still wins")
        XCTAssertNil(s.applyingOptimistically(.endUnit), "Other taps wait for the phone")
        XCTAssertNil(state(scoring(score(tt, String(repeating: "u", count: 11)))).applyingOptimistically(.pointUs),
                     "Nothing to show after the game is decided")
        XCTAssertNotNil(state(scoring(score(tt, "u"))).applyingOptimistically(.undo))
        XCTAssertNil(state(.ended(.init(title: "", line: ""))).applyingOptimistically(.pointUs))
    }

    func testKeepAnswersStillPlayingLocally() {
        let s = state(scoring(score(tt, "")), still: .init(askedAt: t0, minutes: 30, answerWindowSec: 120))
        XCTAssertNil(s.applyingOptimistically(.keepPlaying)?.stillPlaying)
        XCTAssertNil(state(scoring(score(tt, ""))).applyingOptimistically(.keepPlaying))
    }

    func testOnlyANewerSnapshotOrAnotherSessionReplacesTheCurrentOne() {
        let current = state(scoring(score(tt, "")), revision: 10)
        XCTAssertTrue(RacketWatchState.accepts(current, over: nil))
        XCTAssertTrue(RacketWatchState.accepts(state(scoring(score(tt, "u")), revision: 11), over: current))
        XCTAssertFalse(RacketWatchState.accepts(state(scoring(score(tt, "u")), revision: 9), over: current),
                       "A late, queued snapshot is ignored")
        var other = state(scoring(score(tt, "")), revision: 1)
        other.sessionID = UUID()
        XCTAssertTrue(RacketWatchState.accepts(other, over: current), "A new match starts fresh")
    }

    func testStillPlayingAndStoppedCopy() {
        let still = RacketWatchState.StillPlaying(askedAt: t0, minutes: 45, answerWindowSec: 120)
        XCTAssertEqual(still.reason, "No taps or marks for 45 min", "The configured threshold (review5 M4)")
        XCTAssertEqual(still.stopsLine(now: at(30)), "Stops in 1:30")
        XCTAssertEqual(still.stopsLine(now: at(500)), "Stops in 0:00")
        let stop = RacketWatchState.Notice(reason: .storageFull, canResume: false, savedUpToSec: 1864)
        XCTAssertEqual(stop.title, "Recording stopped")
        XCTAssertTrue(stop.line.hasPrefix("Everything up to 31:04 is saved."))
        XCTAssertEqual(RacketWatchState.Notice(reason: .call, canResume: true, savedUpToSec: nil).title, "Recording paused")
        XCTAssertTrue(RacketWatchState.Notice(reason: .call, canResume: true, savedUpToSec: nil).line.contains("Resume on the phone"))
    }

    func testHapticCues() {
        let block = state(.block(.init(index: 0, blocks: 3, startedAt: t0, totalSec: 60, recording: true)))
        let rest = state(.rest(.init(after: 0, blocks: 3, endsAt: at(60), remainingSec: 0, totalSec: 60, paused: false,
                                     done: false, autoStart: true)))
        let countdown = state(.countdown(.init(block: 1, blocks: 3, endsAt: at(5), totalSec: 5)))
        XCTAssertEqual(RacketWatchCue.between(block, rest), .phase)
        XCTAssertEqual(RacketWatchCue.between(rest, countdown), .start, "The Watch taps you before a block starts")
        XCTAssertNil(RacketWatchCue.between(rest, rest))
        XCTAssertEqual(RacketWatchCue.between(rest, state(rest.surface, still: .init(askedAt: t0, minutes: 30, answerWindowSec: 120))), .ask)
        XCTAssertEqual(RacketWatchCue.between(block, state(block.surface, notice: .init(reason: .tooHot, canResume: false, savedUpToSec: nil))), .stopped)
        XCTAssertEqual(RacketWatchCue.between(rest, state(.ended(.init(title: "", line: "")))), .done)
        XCTAssertEqual(RacketWatchCue.between(state(scoring(score(tt, ""), unit: 1)), state(scoring(score(tt, ""), unit: 2))), .start)
        XCTAssertNil(RacketWatchCue.between(nil, nil))
    }

    // MARK: - Phone: the recording screen ↔ Watch

    func testADrillWaitingOnTheCameraOffersStartOnTheWatch() {
        let m = drillMachine()
        let s = RacketWatchBridge.coverState(m, context: ctx, score: RacketLiveScore(rules: tt), now: t0)
        guard case .start(let start) = s.surface else { return XCTFail("XxWatchStart") }
        XCTAssertEqual(start.title, "Start block 1?")
        XCTAssertTrue(start.cameraReady)
        XCTAssertNil(s.note, "Drills have no score note")
    }

    func testWatchStartAndDrillTimersDriveTheMachine() {
        var m = drillMachine()
        var sc = RacketLiveScore(rules: tt)
        _ = RacketWatchBridge.apply(.start, to: &m, score: &sc, now: t0)
        XCTAssertEqual(m.phase, .countdown(block: 0, endsAt: at(5)))
        _ = RacketWatchBridge.apply(.add30, to: &m, score: &sc, now: at(1))
        XCTAssertEqual(m.phase, .countdown(block: 0, endsAt: at(35)), "+30 s on the countdown")
        XCTAssertEqual(m.tick(now: at(35)), [.startCapture])
        guard case .block = RacketWatchBridge.coverState(m, context: ctx, score: sc, now: at(36)).surface else {
            return XCTFail("XxWatchBlock")
        }
        let end = RacketWatchBridge.apply(.endBlock, to: &m, score: &sc, now: at(95))
        XCTAssertEqual(end.effects, [.logBlock(index: 0, durationSec: 60)])
        _ = RacketWatchBridge.apply(.pauseTimer, to: &m, score: &sc, now: at(105))
        XCTAssertEqual(m.phase, .restPaused(after: 0, remaining: 50))
        _ = RacketWatchBridge.apply(.add60, to: &m, score: &sc, now: at(106))
        _ = RacketWatchBridge.apply(.resumeTimer, to: &m, score: &sc, now: at(110))
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(220)))
        let rest = RacketWatchBridge.coverState(m, context: ctx, score: sc, now: at(110))
        guard case .rest(let r) = rest.surface else { return XCTFail("XxWatchRest") }
        XCTAssertEqual(r.endsAt, at(220))
        XCTAssertTrue(r.autoStart)
        _ = RacketWatchBridge.apply(.skip, to: &m, score: &sc, now: at(120))
        XCTAssertEqual(m.phase, .countdown(block: 1, endsAt: at(125)), "Skip rest → the next block's countdown")
        let finish = RacketWatchBridge.apply(.finishDrill, to: &m, score: &sc, now: at(121))
        XCTAssertEqual(finish.effects.last, .ended(.drillReview))
    }

    func testWatchScoreTapsTallyTheGameAndAFinishedGameIsLoggedAndMarked() {
        var m = matchMachine()
        m.start(now: t0)
        var sc = RacketLiveScore(rules: tt)
        var finished: RacketLiveUnitResult?
        for i in 0..<11 {
            let out = RacketWatchBridge.apply(.pointUs, to: &m, score: &sc, now: at(Double(i + 1)))
            if let r = out.unitFinished { finished = r }
        }
        XCTAssertEqual(finished, .init(scoreFor: 11, scoreAgainst: 0))
        XCTAssertEqual(m.log?.newGameMarkCount, 1, "A finished game marks a new game for the split")
        let s = RacketWatchBridge.coverState(m, context: ctx, score: sc, now: at(12))
        guard case .marks(let marks) = s.surface else { return XCTFail("XxWatchMark") }
        XCTAssertTrue(marks.clock.running)
        XCTAssertEqual(marks.markCount, 1)
    }

    func testWatchMarksAndUndo() {
        var m = matchMachine()
        m.start(now: t0)
        var sc = RacketLiveScore(rules: tt)
        _ = RacketWatchBridge.apply(.pointThem, to: &m, score: &sc, now: at(1))
        _ = RacketWatchBridge.apply(.undo, to: &m, score: &sc, now: at(2))
        XCTAssertTrue(sc.isEmpty)
        _ = RacketWatchBridge.apply(.mark, to: &m, score: &sc, now: at(3))
        _ = RacketWatchBridge.apply(.breakStarts, to: &m, score: &sc, now: at(4))
        let reset = RacketWatchBridge.apply(.newUnit, to: &m, score: &sc, now: at(5))
        XCTAssertTrue(reset.resetScore)
        // The first point of a game marks that play started (prompt 246, for the split); it isn't a user mark.
        XCTAssertEqual(m.log?.marks.compactMap(\.kind), [.firstPoint, .moment, .breakStart, .newGame])
        XCTAssertEqual(m.log?.userMarkCount, 3)
        let stop = RacketWatchBridge.apply(.stopAndSplit, to: &m, score: &sc, now: at(6))
        XCTAssertEqual(stop.effects, [.stopCapture, .ended(.splitPrompt)])
        XCTAssertEqual(RacketWatchBridge.apply(.pointUs, to: &m, score: &sc, now: at(7)), .init(), "Nothing after the end")
    }

    func testWatchTapsCountAsActivityForStillPlaying() {
        var m = matchMachine(still: 30)
        m.start(now: t0)
        var sc = RacketLiveScore(rules: tt)
        _ = RacketWatchBridge.apply(.pointUs, to: &m, score: &sc, now: at(25 * 60))
        XCTAssertEqual(m.tick(now: at(30 * 60)), [], "The Watch tap reset the clock")
        XCTAssertEqual(m.tick(now: at(55 * 60)), [.askStillPlaying])
        let s = RacketWatchBridge.coverState(m, context: ctx, score: sc, now: at(55 * 60))
        XCTAssertEqual(s.stillPlaying?.minutes, 30, "The configured threshold reaches the Watch (M4)")
        _ = RacketWatchBridge.apply(.keepPlaying, to: &m, score: &sc, now: at(55 * 60 + 10))
        XCTAssertNil(m.stillPlayingAskedAt)
    }

    func testStopOnTheWatchesStillPlayingEndsTheRecording() {
        var m = matchMachine(still: 30)
        m.start(now: t0)
        m.tick(now: at(30 * 60))
        var sc = RacketLiveScore(rules: tt)
        let out = RacketWatchBridge.apply(.stopRecording, to: &m, score: &sc, now: at(30 * 60 + 5))
        XCTAssertEqual(out.effects, [.stopCapture, .ended(.splitPrompt)])
        XCTAssertFalse(m.endedByStillPlaying, "The player stopped it")
    }

    func testTheWatchIsToldWhyRecordingStopped() {
        var m = matchMachine(still: 30)
        m.start(now: t0)
        m.interrupt(.storageFull, now: at(100))
        var s = RacketWatchBridge.coverState(m, context: ctx, score: RacketLiveScore(rules: tt), now: at(101))
        XCTAssertEqual(s.notice, .init(reason: .storageFull, canResume: false, savedUpToSec: 100))
        guard case .marks(let marks) = s.surface else { return XCTFail("Still the marks board underneath") }
        XCTAssertFalse(marks.clock.running, "The recorded clock stops")
        XCTAssertEqual(marks.clock.seconds(now: at(500)), 100)

        var hot = matchMachine()
        hot.start(now: t0)
        hot.interrupt(.call, now: at(10))
        s = RacketWatchBridge.coverState(hot, context: ctx, score: RacketLiveScore(rules: tt), now: at(11))
        XCTAssertEqual(s.notice?.canResume, true)

        var quiet = matchMachine(still: 30)
        quiet.start(now: t0)
        quiet.tick(now: at(1800))
        quiet.tick(now: at(1800 + 120))
        XCTAssertTrue(quiet.endedByStillPlaying)
        s = RacketWatchBridge.coverState(quiet, context: ctx, score: RacketLiveScore(rules: tt), now: at(1921))
        XCTAssertEqual(s.notice?.reason, .stillPlayingTimeout)
        guard case .ended = s.surface else { return XCTFail("Ended") }
    }

    func testRecordedClockIsStableBetweenEvents() {
        var m = matchMachine()
        m.start(now: t0)
        let a = RacketWatchBridge.recordedClock(m)
        m.tick(now: at(30))
        XCTAssertEqual(RacketWatchBridge.recordedClock(m), a, "No snapshot needed every second")
        XCTAssertEqual(a.seconds(now: at(30)), 30)
        m.interrupt(.call, now: at(40))
        m.resume(now: at(60))
        XCTAssertEqual(RacketWatchBridge.recordedClock(m).seconds(now: at(70)), 50, "The gap isn't recorded time")
    }

    // MARK: - Phone: a game-by-game match on the Watch

    func testGameByGameStartScoreEndBreakNext() {
        var w = RacketWatchMatch(exerciseID: sid, unitIndex: 0, rules: tt, breakSec: 60)
        XCTAssertEqual(w.state(context: ctx).surface.kind, "start")
        guard case .start(let start) = w.state(context: ctx).surface else { return XCTFail() }
        XCTAssertEqual(start.title, "Start game 1?")
        XCTAssertFalse(start.cameraReady)
        XCTAssertEqual(w.apply(.start, now: t0), [.startUnitTimer(t0)])
        XCTAssertEqual(w.apply(.endUnit, now: at(1)), [], "Nothing to log before a point")
        for _ in 0..<11 { _ = w.apply(.pointUs, now: at(2)) }
        for _ in 0..<9 { _ = w.apply(.pointThem, now: at(2)) }   // ignored: 11–0 already decided
        _ = w.apply(.undo, now: at(3))
        _ = w.apply(.pointUs, now: at(3))
        XCTAssertEqual(w.apply(.endUnit, now: at(300)), [.logUnit(.init(scoreFor: 11, scoreAgainst: 0), durationSec: 300)])
        w.logged(unitCount: 1, rules: tt, lastLabel: "11–0", decided: false, fromWatch: true, now: at(300))
        guard case .matchBreak(let b) = w.state(context: ctx).surface else { return XCTFail("WatchBreak") }
        XCTAssertEqual(b.unitScore, "11–0")
        XCTAssertEqual(b.unitNumber, 1)
        XCTAssertEqual(b.endsAt, at(360))
        _ = w.apply(.pauseTimer, now: at(320))
        XCTAssertEqual(w.phase, .breakTime(endsAt: nil, remaining: 40, paused: true))
        _ = w.apply(.add30, now: at(321))
        _ = w.apply(.resumeTimer, now: at(330))
        XCTAssertEqual(w.phase, .breakTime(endsAt: at(400), remaining: 0, paused: false))
        XCTAssertEqual(w.tick(now: at(399)), [])
        XCTAssertEqual(w.tick(now: at(400)), [.startUnitTimer(at(400))], "The break ends: the next game starts")
        guard case .scoring(let sc) = w.state(context: ctx).surface else { return XCTFail() }
        XCTAssertEqual(sc.unitNumber, 2)
        XCTAssertTrue(sc.score.isEmpty)
    }

    func testSkipBreakAndHoldToEndMatch() {
        var w = RacketWatchMatch(exerciseID: sid, unitIndex: 2, rules: tt, breakSec: 60, startedAt: t0)
        _ = w.apply(.pointThem, now: at(1))
        let end = w.apply(.endMatch, now: at(100))
        XCTAssertEqual(end, [.logUnit(.init(scoreFor: 0, scoreAgainst: 1), durationSec: 100), .endMatch],
                       "Hold to end match logs the game being played")
        XCTAssertEqual(w.phase, .ended)
        var b = RacketWatchMatch(exerciseID: sid, unitIndex: 0, rules: tt, breakSec: 60)
        b.logged(unitCount: 1, rules: tt, lastLabel: "11–9", decided: false, fromWatch: true, now: t0)
        XCTAssertEqual(b.apply(.skip, now: at(5)), [.startUnitTimer(at(5))])
    }

    func testPhoneLoggedUnitsAndADecidedMatch() {
        var w = RacketWatchMatch(exerciseID: sid, unitIndex: 0, rules: tt, breakSec: 60)
        w.startedOnPhone(at: t0)
        XCTAssertEqual(w.phase, .scoring(startedAt: t0), "The phone's Start game starts the Watch too")
        w.logged(unitCount: 1, rules: tt, lastLabel: "11–7", decided: false, fromWatch: false, now: at(5))
        XCTAssertEqual(w.phase, .ready, "Logged on the phone: the Watch offers the next game")
        w.logged(unitCount: 1, rules: tt, lastLabel: "11–7", decided: true, fromWatch: false, now: at(6))
        XCTAssertEqual(w.phase, .ready, "Same count: nothing moves")
        w.logged(unitCount: 3, rules: tt, lastLabel: "11–5", decided: true, fromWatch: true, now: at(7))
        XCTAssertEqual(w.phase, .ended)
        let c = RacketWatchContext(sessionID: sid, sport: .tableTennis, sideUs: "You", sideThem: "Alex", unitNumber: 4,
                                   matchLine: "Won 3–0")
        guard case .ended(let e) = w.state(context: c).surface else { return XCTFail() }
        XCTAssertEqual(e.title, "Won 3–0")
    }

    func testBreakDefaults() {
        XCTAssertEqual(RacketWatchMatch.defaultBreakSec(.tableTennis), 60)
        XCTAssertEqual(RacketWatchMatch.defaultBreakSec(.squash), 90)
        XCTAssertEqual(RacketWatchMatch.defaultBreakSec(.tennis), 120)
    }

    // MARK: - Phone: from-Watch scores, copy, de-dupe

    func testAWatchTalliedGameCountsAndReadsFromWatchUntilConfirmed() {
        var log = SetLog(watchResult: .init(scoreFor: 11, scoreAgainst: 9), durationSec: 400)
        XCTAssertEqual(log.racketScoreState, .fromWatch(RacketUnitScore(scoreFor: 11, scoreAgainst: 9)))
        XCTAssertEqual(log.racketScoreState?.label, "11–9 from Watch")
        XCTAssertEqual(log.racketScoreState?.needsConfirming, true)
        let ex = racketMatch(games: [log])
        XCTAssertEqual(ex.racketState.won, 1, "A Watch tally counts")
        log.scoreFromWatch = nil
        XCTAssertEqual(log.racketScoreState, .confirmed(RacketUnitScore(scoreFor: 11, scoreAgainst: 9)))
        XCTAssertEqual(RacketScoreState.unconfirmed.needsConfirming, true)
        let set = SetLog(watchResult: .init(scoreFor: 7, scoreAgainst: 6, tiebreakFor: 7, tiebreakAgainst: 4), durationSec: nil)
        XCTAssertEqual(set.racketScore?.label, "7–6 (4)")
        XCTAssertNil(set.superTiebreak)
    }

    func testEditingAScoreInSessionDetailConfirmsIt() {
        var log = SetLog(watchResult: .init(scoreFor: 11, scoreAgainst: 9), durationSec: nil)
        var seed = SessionSetEditing.Draft()
        seed.scoreFor = "11"; seed.scoreAgainst = "9"
        var d = seed
        d.scoreAgainst = "8"
        SessionSetEditing.apply(d, seed: seed, to: &log, discipline: .racket, kind: .duration, unit: .kg, distanceUnit: .km)
        XCTAssertEqual(log.scoreAgainst, 8)
        XCTAssertNil(log.scoreFromWatch)
    }

    func testSidesAndMatchLine() {
        XCTAssertTrue(RacketWatchCopy.sides(opponent: "Alex Chen", doubles: false) == ("You", "Alex"))
        XCTAssertTrue(RacketWatchCopy.sides(opponent: nil, doubles: false) == ("You", "Them"))
        XCTAssertTrue(RacketWatchCopy.sides(opponent: "Alex", doubles: true) == ("Us", "Them"))
        let won = SetLog(watchResult: .init(scoreFor: 11, scoreAgainst: 9), durationSec: nil)
        let ex = racketMatch(games: [won])
        XCTAssertEqual(RacketWatchCopy.matchLine(ex.racketState, unit: .game), "Games 1–0")
        XCTAssertNil(RacketWatchCopy.matchLine(racketMatch().racketState, unit: .game))
        let c = RacketWatchContext(ex)
        XCTAssertEqual(c.unitNumber, 2)
        XCTAssertEqual(c.sideThem, "Alex")
        XCTAssertEqual(c.matchLine, "Games 1–0")
    }

    func testCommandLedgerAppliesEachTapOnce() {
        var l = RacketWatchCommandLedger(capacity: 2)
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(l.firstTime(a))
        XCTAssertFalse(l.firstTime(a), "A re-sent copy is dropped")
        XCTAssertTrue(l.firstTime(b))
        XCTAssertTrue(l.firstTime(c))
        XCTAssertEqual(l.ids, [b, c], "Only the last few are kept")
    }
}
