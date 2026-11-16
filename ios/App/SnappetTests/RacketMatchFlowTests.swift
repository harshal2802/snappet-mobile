import XCTest
@testable import Snappet

/// Unit tests for the **pure** game-by-game match flow (prompt 249, issue #438 parity): warmup → game → interval
/// (badminton) → score → break → countdown → next game → match over, scoring without video, who serves, phone heat,
/// the per-sport copy, padel's golden point, the machine recording each game as its own run, the split Your videos
/// reads, and the Watch mapping. No device, no camera.
final class RacketMatchFlowTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func flow(_ sport: RacketSport = .tableTennis, filming: Bool = true, pointsTo: Int? = nil) -> RacketGameFlow {
        RacketGameFlow(filming: filming, unitIndex: 0,
                       options: .init(sport: sport, pointsTo: pointsTo ?? sport.defaultPointsTo))
    }

    private func rally(_ to: Int, cap: Int? = nil) -> RacketLiveScore { RacketLiveScore(rules: .init(kind: .rally, pointsTo: to, cap: cap)) }

    // MARK: Flow

    func testWarmupStartsTheGameAndRecordingAtOnce() {
        var f = flow()
        XCTAssertEqual(f.phase, .warmup)
        XCTAssertFalse(f.wantsCapture, "warmup saves nothing (game by game)")
        XCTAssertEqual(f.startGame(now: t0), [.resumeCapture])
        XCTAssertEqual(f.phase, .playing)
        XCTAssertEqual(f.gameStartedAt, t0)
        XCTAssertTrue(f.wantsCapture)
    }

    func testNextGameScoresThenBreakThenCountdownThenTheNextGame() {
        var f = flow()
        f.startGame(now: t0)
        XCTAssertEqual(f.endGame(matchOver: false, now: at(600)), [.openScore])
        XCTAssertEqual(f.phase, .scoring(matchOver: false))
        XCTAssertTrue(f.wantsCapture, "the game's clip runs until the score is saved")
        XCTAssertEqual(f.saved(startBreak: true, decided: false, now: at(620)), [.pauseCapture], "Pause recording during the break: on")
        XCTAssertEqual(f.unitIndex, 1)
        XCTAssertEqual(f.phase, .breakTime(endsAt: at(680)), "table tennis breaks for 1:00")
        XCTAssertEqual(f.display(now: at(650))?.word, "Break")
        XCTAssertEqual(f.display(now: at(650))?.tone, .rest, "the break ring is grey")
        XCTAssertEqual(f.tick(now: at(680)), [])
        XCTAssertEqual(f.phase, .countdown(endsAt: at(683)), "auto-start: the countdown")
        XCTAssertEqual(f.tick(now: at(683)), [.resumeCapture], "recording starts at zero")
        XCTAssertEqual(f.phase, .playing)
        XCTAssertEqual(f.gameStartedAt, at(683))
    }

    func testBreakPauseAddSkipAndWaitReturnToAPausedBreak() {
        var f = flow()
        f.startGame(now: t0)
        f.endGame(matchOver: false, now: at(10))
        f.saved(startBreak: true, decided: false, now: at(10))
        f.pauseBreak(now: at(30))
        XCTAssertEqual(f.phase, .breakPaused(remaining: 40))
        XCTAssertEqual(f.display(now: at(99))?.tone, .restPaused, "paused is grey at 0.55")
        f.addBreak(30)
        XCTAssertEqual(f.phase, .breakPaused(remaining: 70))
        f.resumeBreak(now: at(100))
        XCTAssertEqual(f.phase, .breakTime(endsAt: at(170)))
        f.skipBreak(now: at(110))
        XCTAssertEqual(f.phase, .countdown(endsAt: at(113)))
        f.extendCountdown(by: 30)
        XCTAssertEqual(f.phase, .countdown(endsAt: at(143)))
        f.wait()
        XCTAssertEqual(f.phase, .breakPaused(remaining: 0), "Wait returns to a paused break timer")
    }

    func testAutoStartOffWaitsAndADecidedMatchNeverAutoStarts() {
        var f = flow()
        f.options.autoStart = false
        f.startGame(now: t0)
        f.endGame(matchOver: false, now: at(10))
        f.saved(startBreak: true, decided: false, now: at(10))
        f.tick(now: at(70))
        XCTAssertEqual(f.phase, .breakDone)
        XCTAssertEqual(f.startGame(now: at(80)), [.resumeCapture])

        var g = flow()
        g.startGame(now: t0)
        g.endGame(matchOver: false, now: at(10))
        g.saved(startBreak: true, decided: true, now: at(10))
        XCTAssertFalse(g.breakAutoStart, "Auto-start stops once the score decides the match")
        g.tick(now: at(70))
        XCTAssertEqual(g.phase, .breakDone)
    }

    func testRecordedBreakKeepsCapturing() {
        var f = flow()
        f.options.pauseRecordingInBreak = false
        f.startGame(now: t0)
        f.endGame(matchOver: false, now: at(10))
        XCTAssertEqual(f.saved(startBreak: true, decided: false, now: at(10)), [])
        XCTAssertTrue(f.wantsCapture)
    }

    func testStopAndMatchOverEndTheMatch() {
        var f = flow()
        f.startGame(now: t0)
        f.endGame(matchOver: true, now: at(10))
        XCTAssertEqual(f.phase, .scoring(matchOver: true))
        XCTAssertEqual(f.saved(startBreak: true, decided: false, now: at(12)), [.pauseCapture, .matchOver],
                       "Stop → Score sheet, then match over whatever is tapped")
        XCTAssertTrue(f.isEnded)

        var g = flow()
        g.startGame(now: t0)
        g.endGame(matchOver: false, now: at(10))
        XCTAssertEqual(g.saved(startBreak: false, decided: false, now: at(12)), [.pauseCapture, .matchOver], "Save, match over")

        var h = flow()
        h.startGame(now: t0)
        h.endGame(matchOver: false, now: at(10))
        h.saved(startBreak: true, decided: false, now: at(12))
        XCTAssertEqual(h.endMatch(), [.pauseCapture, .matchOver], "End match on the break")
    }

    func testCancelledScoreGoesBackToTheGame() {
        var f = flow()
        f.startGame(now: t0)
        f.endGame(matchOver: false, now: at(10))
        f.cancelScore()
        XCTAssertEqual(f.phase, .playing)
        XCTAssertEqual(f.unitIndex, 0)
    }

    func testScoreOnlyNeverTouchesTheCamera() {
        var f = RacketGameFlow(filming: false, unitIndex: 2, options: .init(sport: .squash, pointsTo: 11), startInWarmup: false)
        XCTAssertEqual(f.phase, .playing)
        XCTAssertEqual(f.endGame(matchOver: false, now: t0), [.openScore])
        XCTAssertEqual(f.saved(startBreak: true, decided: false, now: t0), [])
        XCTAssertEqual(f.options.breakSec, 90, "squash breaks for 1:30")
        XCTAssertFalse(f.wantsCapture)
        f.skipBreak(now: t0)
        XCTAssertEqual(f.tick(now: at(3)), [])
        XCTAssertEqual(f.phase, .playing)
        XCTAssertEqual(f.unitIndex, 3)
    }

    func testAFinishedTallyOpensTheScoreSheet() {
        var f = flow()
        f.startGame(now: t0)
        var s = rally(11)
        for _ in 0..<11 { s.point(.us) }
        XCTAssertEqual(f.pointsChanged(s, now: at(5)), [.openScore])
        XCTAssertEqual(f.phase, .scoring(matchOver: false))
    }

    // MARK: Interval (BdInterval)

    func testBadmintonIntervalAtElevenOnceAKeepsRecordingByDefault() {
        var f = flow(.badminton)
        XCTAssertEqual(f.options.intervalAt, 11)
        f.startGame(now: t0)
        var s = rally(21, cap: 30)
        for _ in 0..<10 { s.point(.us) }
        XCTAssertEqual(f.pointsChanged(s, now: at(1)), [])
        s.point(.us)
        XCTAssertEqual(f.pointsChanged(s, now: at(2)), [], "Off keeps one clip for the game")
        XCTAssertEqual(f.phase, .interval(endsAt: at(62)))
        XCTAssertEqual(f.display(now: at(20))?.word, "Interval")
        XCTAssertEqual(f.display(now: at(20))?.seconds, 42)
        XCTAssertTrue(f.wantsCapture)
        f.pauseInterval(now: at(20))
        XCTAssertEqual(f.phase, .intervalPaused(remaining: 42))
        f.addInterval(30)
        f.resumeInterval(now: at(30))
        XCTAssertEqual(f.phase, .interval(endsAt: at(102)))
        XCTAssertEqual(f.setPauseRecordingInInterval(true), [.pauseCapture])
        XCTAssertEqual(f.tick(now: at(102)), [.resumeCapture], "the game continues, recording again")
        XCTAssertEqual(f.phase, .playing)
        s.point(.them)
        XCTAssertEqual(f.pointsChanged(s, now: at(110)), [], "the interval comes once a game")
        XCTAssertEqual(f.phase, .playing)
    }

    func testIntervalOnlyInBadmintonAndAtEightInAGameToFifteen() {
        XCTAssertNil(RacketGameFlow.intervalAt(sport: .tableTennis, pointsTo: 11))
        XCTAssertNil(RacketGameFlow.intervalAt(sport: .squash, pointsTo: 11))
        XCTAssertEqual(RacketGameFlow.intervalAt(sport: .badminton, pointsTo: 15), 8)
    }

    // MARK: Who serves

    func testTableTennisServeAlternatesEveryTwoThenEveryPointFromTenAll() {
        func server(_ p: Int, game: Int = 0) -> RacketServe.Side? {
            RacketServe.server(sport: .tableTennis, firstServer: .us, unitIndex: game, previous: [],
                               points: Array(repeating: .us, count: p))
        }
        XCTAssertEqual(server(0), .us)
        XCTAssertEqual(server(1), .us)
        XCTAssertEqual(server(2), .them)
        XCTAssertEqual(server(4), .us)
        XCTAssertEqual(server(20), .us, "10–10: two-serve blocks alternate evenly")
        XCTAssertEqual(server(21), .them, "then every point")
        XCTAssertEqual(server(0, game: 1), .them, "the receiver of game 1 serves first in game 2")
        XCTAssertNil(RacketServe.server(sport: .tableTennis, firstServer: nil, unitIndex: 0, previous: [], points: []))
    }

    func testRallyWinnerServesAndThePreviousGamesWinnerStarts() {
        XCTAssertEqual(RacketServe.server(sport: .badminton, firstServer: .us, unitIndex: 0, previous: [], points: [.them]), .them)
        XCTAssertEqual(RacketServe.server(sport: .squash, firstServer: .them, unitIndex: 0, previous: [], points: []), .them)
        let won = RacketUnitScore(scoreFor: 21, scoreAgainst: 15, tiebreakFor: nil, tiebreakAgainst: nil, superTiebreak: false)
        XCTAssertEqual(RacketServe.server(sport: .badminton, firstServer: .them, unitIndex: 1, previous: [won], points: []), .us)
    }

    func testTennisServerChangesEachGameAndInTheTiebreak() {
        let four: [RacketLiveScore.Side] = Array(repeating: .us, count: 4)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: []), .us)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: four), .them)
        let set1 = RacketUnitScore(scoreFor: 6, scoreAgainst: 3, tiebreakFor: nil, tiebreakAgainst: nil, superTiebreak: false)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 1, previous: [set1], points: []), .them,
                       "nine games played: the other side serves first in set 2")
        // 6–6 (12 games alternately won), then the tiebreak: the 13th server serves one, then two each.
        var pts: [RacketLiveScore.Side] = []
        for g in 0..<12 { pts += Array(repeating: g % 2 == 0 ? .us : .them, count: 4) }
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: pts), .us)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: pts + [.us]), .them)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: pts + [.us, .us]), .them)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: pts + [.us, .us, .us]), .us)
    }

    // MARK: Heat

    func testThermalLevels() {
        XCTAssertEqual(RacketThermalLevel.from(rawValue: 0), .ok)
        XCTAssertEqual(RacketThermalLevel.from(rawValue: 1), .ok)
        XCTAssertEqual(RacketThermalLevel.from(rawValue: 2), .warm)
        XCTAssertEqual(RacketThermalLevel.from(rawValue: 3), .tooHot)
        XCTAssertEqual(RacketThermalLevel.ok.headerLabel, "Phone OK")
        XCTAssertEqual(RacketThermalLevel.warm.headerLabel, "▲ Warm")
    }

    // MARK: Rules

    func testPadelGoldenPointDecidesAtFortyAll() {
        let golden = RacketLiveRules(format: RacketFormat(sport: .padel, bestOf: 3, goldenPoint: true), unitIndex: 0)
        XCTAssertEqual(golden.goldenPoint, true)
        var s = RacketLiveScore(rules: golden)
        for _ in 0..<3 { s.point(.us); s.point(.them) }
        XCTAssertEqual(s.display, "40 – 40")
        s.point(.them)
        XCTAssertEqual(s.tally.gamesAgainst, 1, "golden point: the next point wins the game")
        XCTAssertEqual(s.display, "0 – 0")

        var adv = RacketLiveScore(rules: RacketLiveRules(format: RacketFormat(sport: .padel, bestOf: 3), unitIndex: 0))
        XCTAssertNil(adv.rules.goldenPoint)
        for _ in 0..<3 { adv.point(.us); adv.point(.them) }
        adv.point(.them)
        XCTAssertEqual(adv.display, "40 – Ad", "Advantage keeps playing")
        XCTAssertFalse(RacketFormat(sport: .tennis, bestOf: 3, goldenPoint: false).goldenPoint)
        XCTAssertFalse(RacketFormat(sport: .squash, bestOf: 3, goldenPoint: true).goldenPoint, "sets sports only")
    }

    func testBadmintonGamesToFifteenCapAtTwentyOne() {
        XCTAssertEqual(RacketFormat(sport: .badminton, bestOf: 3).cap, 30)
        XCTAssertEqual(RacketFormat(sport: .badminton, bestOf: 3, pointsTo: 15).cap, 21)
        XCTAssertNil(RacketFormat(sport: .squash, bestOf: 5, pointsTo: 15).cap)
        XCTAssertEqual(RacketSport.badminton.pointsToOptions, [21, 15])
        XCTAssertEqual(RacketSport.squash.pointsToOptions, [11, 15])
    }

    // MARK: Copy

    func testCopyPerSport() {
        XCTAssertEqual(RacketGameCopy.recordingLine(.tableTennis), "Recording. Rallies will be found after the game.")
        XCTAssertEqual(RacketGameCopy.recordingLine(.badminton), "Recording. Rallies will be found after the match.")
        XCTAssertEqual(RacketGameCopy.pointsLabel(.tableTennis), "Points played")
        XCTAssertEqual(RacketGameCopy.pointsLabel(.squash), "Points tagged")
        XCTAssertEqual(RacketGameCopy.statsAfterLine(.tennis), "Rally and shot stats appear after the match.")
        XCTAssertEqual(RacketGameCopy.warmupLine(.set), "Game by game saves nothing until you start the set. Everything records warmup too.")
        XCTAssertEqual(RacketGameCopy.scoreSubtitle(sport: .badminton, fromWatch: true, cap: 30),
                       "Win by 2, capped at 30. Filled in from your Watch.")
        XCTAssertEqual(RacketGameCopy.scoreSubtitle(sport: .tableTennis, fromWatch: true, cap: nil),
                       "Filled in from your Watch taps. Fix it now or later.")
        XCTAssertEqual(RacketGameCopy.scoreSubtitle(sport: .padel, fromWatch: true, cap: nil), "Games in this set. Filled in from your Watch.")
        XCTAssertEqual(RacketGameCopy.scoreSubtitle(sport: .squash, fromWatch: false, cap: nil), "Win by 2.")
        XCTAssertEqual(RacketGameCopy.breakChips(.tableTennis), [30, 60, 120, 300])
        XCTAssertEqual(RacketGameCopy.breakChips(.squash), [90, 120, 300])
        XCTAssertEqual(RacketGameCopy.breakChips(.badminton), [60, 120, 300])
        XCTAssertEqual(RacketGameCopy.breakLine(unit: .game, next: 2, autoStart: true), "Game 2 starts by itself after this")
        XCTAssertEqual(RacketGameCopy.tiebreakLine(unitIndex: 0, gamesTo: 6), "Set 1 · games 6–6 · first to 7, win by 2")
        let head = RacketGameCopy.formatHeader(RacketFormat(sport: .badminton, bestOf: 3))
        XCTAssertEqual(head.top, "Best of 3")
        XCTAssertEqual(head.bottom, "Games to 21")
        XCTAssertEqual(RacketGameCopy.formatHeader(RacketFormat(sport: .tennis, bestOf: 3)).bottom, "Sets to 6")
        XCTAssertEqual(RacketMatchFormChoices.bestOf(.badminton), [3, 1])
        XCTAssertEqual(RacketMatchFormChoices.bestOfLabel(.badminton, 1), "One game")
        XCTAssertEqual(RacketMatchFormChoices.altPointsTo(.squash), 15)
        XCTAssertNil(RacketMatchFormChoices.altPointsTo(.tableTennis))
        XCTAssertEqual(RacketRecapLine.line(durationSec: 5050, bpms: [130, 134]), "1:24:10 · average heart rate 132")
        XCTAssertEqual(RacketRecapLine.line(durationSec: 65, bpms: []), "1:05")
        XCTAssertEqual(RacketClock.recordingHeader(1), "00:01")
        XCTAssertEqual(RacketClock.recordingHeader(581), "09:41")
        XCTAssertEqual(RacketClock.recordingHeader(2900), "48:20")
        XCTAssertEqual(RacketClock.recordingHeader(3724), "1:02:04")
        XCTAssertEqual(RacketStillPlaying.again(minutes: 30, everythingMinutes: 60),
                       "Keep recording asks again in 30 minutes. When you record everything, it waits 60.")
    }

    func testScoreCaption() {
        var s = rally(21, cap: 30)
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .badminton, unitIndex: 0, score: s, server: .us, them: "Alex"),
                       "Game 1 · you’re serving")
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .badminton, unitIndex: 0, score: s, server: .them, them: "Alex"),
                       "Game 1 · Alex serving")
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .squash, unitIndex: 1, score: s, server: nil, them: "Alex"), "Game 2")
        s = rally(11)
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .tableTennis, unitIndex: 0, score: s, server: .us, them: "Alex"), "Game 1")
        s.point(.us)
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .tableTennis, unitIndex: 0, score: s, server: .us, them: "Alex"),
                       "Score from Watch")
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .tableTennis, unitIndex: 0, score: s, server: .us, them: "Alex",
                                                   fromWatch: false), "Game 1", "phone taps aren't from the Watch")
        var t = RacketLiveScore(rules: .init(kind: .sets, pointsTo: 6))
        for _ in 0..<4 { t.point(.us) }
        XCTAssertEqual(RacketGameCopy.scoreCaption(sport: .tennis, unitIndex: 0, score: t, server: .us, them: "Alex"),
                       "Games 1–0 · Set 1")
    }

    // MARK: The machine, game by game

    func testMachineRecordsEachGameAsItsOwnRunWithGameMarks() {
        var m = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: 30, now: t0)
        m.baseSetIndex = 0
        XCTAssertEqual(m.start(now: t0), [.startCapture])
        XCTAssertEqual(m.log?.modeRaw, "byUnit")
        XCTAssertTrue(m.log?.isGameByGame == true)
        m.openGame(index: 0, now: t0)
        XCTAssertEqual(m.pauseCapture(now: at(600)), [.stopCapture])
        m.closeGame(now: at(600))
        XCTAssertFalse(m.capturing)
        XCTAssertEqual(m.tick(now: at(600 + 3600)), [], "no Still playing? while paused between games")
        XCTAssertEqual(m.resumeCapture(now: at(700)), [.startCapture])
        m.openGame(index: 1, now: at(700))
        m.openInterval(now: at(800))
        m.closeInterval(now: at(860))
        m.pauseCapture(now: at(1300))
        m.closeGame(now: at(1300))
        let log = m.log!
        XCTAssertEqual(log.runs.count, 2)
        XCTAssertEqual(log.runs.map(\.endReasonRaw), [nil, nil], "a pause between games isn't an interruption")
        XCTAssertEqual(log.gameIndex(at: 30), 0)
        XCTAssertEqual(log.gameIndex(at: 650), nil, "between games")
        XCTAssertEqual(log.gameIndex(at: 900), 1)
        XCTAssertEqual(log.marks.filter { $0.kind == .interval }.count, 1)
        XCTAssertEqual(log.userMarkCount, 0, "game ranges aren't user marks")

        let parts = RacketGameByGameSplit.parts(log)
        XCTAssertEqual(parts.map(\.kind), [.game, .game], "the unrecorded gap between games isn't a part")
        XCTAssertEqual(parts.map(\.setIndex), [0, 1])
        XCTAssertNotNil(RacketGameByGameSplit.split(log, now: at(1400))?.appliedAt)
    }

    func testRecordedBreakBecomesABreakPartAndStillPlayingAsksGameByGame() {
        var m = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: 30, now: t0)
        m.start(now: t0)
        m.openGame(index: 0, now: t0)
        m.closeGame(now: at(600))
        m.openGame(index: 1, now: at(700))   // recording ran through the break
        XCTAssertEqual(m.tick(now: at(700 + 1800)), [.askStillPlaying], "the game-by-game threshold is read")
        let parts = RacketGameByGameSplit.parts(m.log!)
        XCTAssertEqual(parts.map(\.kind), [.game, .breakTime, .game])
    }

    func testContinueLogAddsToAnEarlierGameByGameRecording() {
        var first = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: t0)
        first.start(now: t0)
        first.end(now: at(60))
        var next = RacketRecordingMachine(kind: .match, recording: .byUnit, stillPlayingMinutes: nil, now: at(900))
        next.continueLog(first.log!)
        next.start(now: at(900))
        XCTAssertEqual(next.log?.startedAt, t0)
        XCTAssertEqual(next.log?.runs.count, 2)
        var everything = RacketRecordingMachine(kind: .match, stillPlayingMinutes: nil, now: t0)
        everything.continueLog(first.log!)
        XCTAssertNil(everything.log, "only game by game continues a log")
    }

    // MARK: The Watch

    func testGameCoverWatchSurfaces() {
        let c = RacketWatchContext(sessionID: UUID(), sport: .tableTennis, sideUs: "You", sideThem: "Alex", unitNumber: 1)
        let s = rally(11)
        var f = flow()
        XCTAssertEqual(RacketWatchBridge.gameCoverState(f, machine: nil, context: c, score: s, lastUnitLabel: nil, now: t0).surface.kind, "start")
        f.startGame(now: t0)
        XCTAssertEqual(RacketWatchBridge.gameCoverState(f, machine: nil, context: c, score: s, lastUnitLabel: nil, now: t0).surface.kind, "scoring")
        f.endGame(matchOver: false, now: at(10))
        f.saved(startBreak: true, decided: false, now: at(10))
        let br = RacketWatchBridge.gameCoverState(f, machine: nil, context: c, score: s, lastUnitLabel: "11–9", now: at(20))
        XCTAssertEqual(br.surface.kind, "break")
        if case .matchBreak(let b) = br.surface { XCTAssertEqual(b.unitNumber, 1); XCTAssertEqual(b.unitScore, "11–9") }
        f.skipBreak(now: at(30))
        let cd = RacketWatchBridge.gameCoverState(f, machine: nil, context: c, score: s, lastUnitLabel: nil, now: at(30))
        XCTAssertEqual(cd.surface.ring(now: at(30))?.word, "Game 2 starts")
        XCTAssertEqual(RacketWatchBridge.gameAction(.pointUs, phase: .playing), .point(us: true))
        XCTAssertEqual(RacketWatchBridge.gameAction(.pointUs, phase: .breakDone), .none)
        XCTAssertEqual(RacketWatchBridge.gameAction(.endUnit, phase: .playing), .endGame)
        XCTAssertEqual(RacketWatchBridge.gameAction(.endMatch, phase: .playing), .endMatch)
        XCTAssertEqual(RacketWatchBridge.gameAction(.add30, phase: .playing), .add(30))
    }

    func testOlderCountdownsStillReadAsBlocks() {
        let cd = RacketWatchState.Surface.countdown(.init(block: 1, blocks: 3, endsAt: at(5), totalSec: 5))
        XCTAssertEqual(cd.ring(now: t0)?.word, "Block 2 starts")
    }
}
