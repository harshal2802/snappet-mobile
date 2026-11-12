import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for **drill parity** (prompt 250, issue #438): block by block records each block as its own part, Pause
/// during a block (every mode), More options, the library / details / goal / copy, the review and progress numbers,
/// the Watch's block Pause, and each split part's own orientation. No device, no camera.
final class RacketDrillFlowTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func drill(_ recording: RacketRecordingMode, blocks: Int = 3, autoStart: Bool = true) -> RacketRecordingMachine {
        let plan = RacketDrillPlan(blocks: blocks, blockSec: 300, restSec: 60, autoStart: autoStart, countdownSec: 5,
                                   recording: recording)
        return RacketRecordingMachine(kind: .drill(plan), recording: recording, stillPlayingMinutes: 30, now: t0)
    }

    // MARK: - Block by block (D1.1)

    func testBlockByBlockRecordsEachBlockAsItsOwnPartAndNothingDuringRest() {
        var m = drill(.byUnit)
        XCTAssertEqual(m.start(now: t0), [])
        XCTAssertEqual(m.tick(now: at(5)), [.startCapture], "block 1 starts recording at zero")
        XCTAssertTrue(m.capturing)
        XCTAssertEqual(m.log?.modeRaw, "byUnit")
        let end = m.endBlock(now: at(65))
        XCTAssertEqual(end, [.logBlock(index: 0, durationSec: 60), .stopCapture], "the rest records nothing")
        XCTAssertFalse(m.capturing)
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(125)))
        // Rest runs out → countdown → block 2 starts a new run (a new Photos part).
        m.tick(now: at(125))
        XCTAssertEqual(m.tick(now: at(130)), [.startCapture])
        XCTAssertEqual(m.log?.runs.count, 2)
        XCTAssertEqual(m.log?.blockMarks.count, 2)
        _ = m.endBlock(now: at(190))
        XCTAssertEqual(m.log?.drillSummaryLine, "2 blocks · 2 clips")
    }

    func testDontFilmNeverRecordsButRunsTheTimers() {
        var m = drill(.off)
        m.start(now: t0)
        XCTAssertEqual(m.tick(now: at(5)), [])
        XCTAssertEqual(m.phase, .block(0, startedAt: at(5)))
        XCTAssertNil(m.log)
        XCTAssertEqual(m.endBlock(now: at(35)), [.logBlock(index: 0, durationSec: 30)])
    }

    func testStartingBlockCountsAbsolutelyAndWaitGoesBackToTheCameraBeforeIt() {
        var m = drill(.byUnit)
        m.startingBlock = 2
        m.start(now: t0)
        XCTAssertEqual(m.phase, .countdown(block: 2, endsAt: at(5)))
        m.wait(now: at(1))
        XCTAssertEqual(m.phase, .ready, "Wait before this run's first block goes back to the camera")
    }

    func testResumeAfterACallBetweenBlocksStaysPausedForBlockByBlock() {
        var m = drill(.byUnit)
        m.start(now: t0); m.tick(now: at(5)); m.endBlock(now: at(65))
        m.interrupt(.call, now: at(70))
        XCTAssertEqual(m.resume(now: at(75)), [], "nothing records during rest")
        XCTAssertNil(m.interruption)
    }

    // MARK: - Pause (Paused / DrillPaused, BlockAll's Pause)

    func testPauseStopsTheBlockTimerAndRecordingThenResumeCarriesOn() {
        for mode in [RacketRecordingMode.byUnit, .everything] {
            var m = drill(mode)
            m.start(now: t0); m.tick(now: at(5))
            XCTAssertEqual(m.pauseBlock(now: at(65)), [.stopCapture], "\(mode): nothing is recorded while paused")
            XCTAssertEqual(m.phase, .blockPaused(0, elapsed: 60))
            XCTAssertEqual(m.display(now: at(500))?.word, "Paused")
            XCTAssertEqual(m.display(now: at(500))?.tone, .restPaused)
            XCTAssertEqual(m.display(now: at(500))?.seconds, 240, "the block timer stopped")
            XCTAssertEqual(m.tick(now: at(1000)), [], "a paused block never runs out")
            XCTAssertEqual(m.resumeBlock(now: at(100)), [.startCapture])
            XCTAssertEqual(m.phase, .block(0, startedAt: at(40)), "\(mode): resumes from where it stopped")
            XCTAssertEqual(m.log?.runs.count, 2, "\(mode): Resume starts a new part")
            XCTAssertEqual(m.log?.runs.first?.endReasonRaw, nil, "a pause isn't an interruption")
        }
    }

    func testEndBlockAndStopDrillFromPausedLogThePlayedTime() {
        var m = drill(.byUnit)
        m.start(now: t0); m.tick(now: at(5)); m.pauseBlock(now: at(95))
        XCTAssertEqual(m.endBlock(now: at(200)), [.logBlock(index: 0, durationSec: 90)])
        var s = drill(.everything)
        s.start(now: t0); s.tick(now: at(5)); s.pauseBlock(now: at(35))
        let effects = s.end(now: at(300))
        XCTAssertEqual(effects.first, .logBlock(index: 0, durationSec: 30))
        XCTAssertEqual(s.phase, .ended(.drillReview))
    }

    func testStillPlayingNeverAsksWhilePaused() {
        var m = drill(.byUnit)
        m.start(now: t0); m.tick(now: at(5)); m.pauseBlock(now: at(10))
        XCTAssertEqual(m.tick(now: at(10 + 3 * 3600)), [])
        XCTAssertNil(m.stillPlayingAskedAt)
    }

    // MARK: - More options

    func testMoreOptionsChangeRestAutoStartAndBlocks() {
        var m = drill(.everything, autoStart: false)
        m.start(now: t0); m.tick(now: at(5)); m.endBlock(now: at(65))
        m.setRestSec(90, now: at(70))
        XCTAssertEqual(m.phase, .rest(after: 0, endsAt: at(160)))
        m.tick(now: at(160))
        XCTAssertEqual(m.phase, .restDone(after: 0))
        m.setAutoStart(true, now: at(170))
        XCTAssertEqual(m.phase, .countdown(block: 1, endsAt: at(175)), "auto-start on starts the countdown")
        m.addBlock(now: at(171))
        XCTAssertEqual(m.plan?.blocks, 4)
        var e = drill(.byUnit, blocks: 5)
        e.start(now: t0); e.tick(now: at(5)); e.endBlock(now: at(65))
        e.endAfterNextBlock(now: at(70))
        XCTAssertEqual(e.plan?.blocks, 2, "block 2 is the last one")
    }

    // MARK: - Watch Pause

    func testWatchPausesAndResumesTheBlock() {
        var m = drill(.byUnit)
        m.start(now: t0); m.tick(now: at(5))
        var score = RacketLiveScore(rules: .init(kind: .rally, pointsTo: 11))
        let out = RacketWatchBridge.apply(.pauseTimer, to: &m, score: &score, now: at(65))
        XCTAssertEqual(out.effects, [.stopCapture])
        let c = RacketWatchContext(sessionID: UUID(), sport: .tableTennis, sideUs: "You", sideThem: "Them", unitNumber: 1)
        let s = RacketWatchBridge.coverState(m, context: c, score: score, now: at(80))
        guard case .block(let b) = s.surface else { return XCTFail("block surface") }
        XCTAssertEqual(b.pausedRemainingSec, 240)
        XCTAssertEqual(s.surface.ring(now: at(500))?.word, "Paused")
        _ = RacketWatchBridge.apply(.resumeTimer, to: &m, score: &score, now: at(90))
        XCTAssertEqual(m.phase, .block(0, startedAt: at(30)))
    }

    // MARK: - Library, details, goal

    func testLibraryFollowsTheBoardsPerSport() {
        XCTAssertEqual(RacketDrillLibrary.items(.tableTennis).count, 8)
        XCTAssertEqual(RacketDrillLibrary.items(.tableTennis).first?.name, "Forehand loop vs block")
        XCTAssertEqual(RacketDrillLibrary.categories(.squash), ["Length", "Volley", "Boast", "Solo", "Ghosting"])
        XCTAssertEqual(RacketDrillLibrary.items(.badminton).first { $0.measure == .time }?.tag, "Timer")
        XCTAssertEqual(RacketDrillLibrary.items(.badminton).first?.tag, "Video helps")
        let serve = RacketDrillLibrary.filtered(.tableTennis, category: "Serve", query: "", recent: [])
        XCTAssertEqual(serve.map(\.name), ["Short backspin serve", "Third-ball attack"])
        let yours = RacketDrillLibraryItem(name: "My drill", measure: .time, categories: [])
        XCTAssertEqual(RacketDrillLibrary.filtered(.tableTennis, category: "All", query: "my", recent: [yours]).map(\.name), ["My drill"])
        XCTAssertTrue(RacketDrillLibrary.isSolo(sport: .squash, name: "Solo rally", practising: nil))
        XCTAssertFalse(RacketDrillLibrary.isSolo(sport: .tennis, name: "Solo rally", practising: nil))
        XCTAssertEqual(RacketDrillLibrary.recentDetail(.longestRally, last: 18), "Longest rally · last 18 shots")
    }

    func testDetailsRoundTripTagsAndTheFirstTimeGate() {
        var d = RacketDrillDetails(practising: "With a partner", hand: "Forehand", stroke: "Drive", pattern: "Straight", goal: 24)
        XCTAssertEqual(d.focusLine, "Forehand drive")
        XCTAssertEqual(d.tags(sport: .badminton), ["With a partner", "Forehand drive", "Straight"])
        XCTAssertEqual(d.tags(sport: .tableTennis), ["With a partner", "Forehand", "Drive", "Straight"])
        var ex = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [], displayName: "D",
                                 kindRaw: nil)
        RacketDrillPlan(details: d).apply(to: &ex)
        XCTAssertEqual(RacketDrillDetails(from: ex), d)
        d.practising = nil
        XCTAssertFalse(d.canStart, "Choose what you're practising and your focus first.")
        XCTAssertEqual(RacketDrillChoices.practising(.badminton), ["With a partner", "Feeder", "Multi-shuttle", "Solo"])
        XCTAssertEqual(RacketDrillChoices.patterns(.padel).first, "At the net")
        XCTAssertEqual(RacketDrillGoal.text(24, measure: .longestRally), "Beat 24 shots")
        XCTAssertEqual(RacketDrillGoal.blockLine(24, measure: .longestRally), "Goal: beat 24 shots")
        XCTAssertNil(RacketDrillGoal.text(24, measure: .time))
        XCTAssertEqual(RacketDrillGoal.lastTime(76, measure: .madeTried), "Last time 76%")
    }

    func testCourtZonesFromThenToThenStartAgain() {
        var (f, t): (Int?, Int?) = (nil, nil)
        (f, t) = RacketCourtZoneRule.tap(8, from: f, to: t); XCTAssertEqual(f, 8); XCTAssertNil(t)
        (f, t) = RacketCourtZoneRule.tap(3, from: f, to: t); XCTAssertEqual(t, 3)
        (f, t) = RacketCourtZoneRule.tap(5, from: f, to: t); XCTAssertEqual(f, 5); XCTAssertNil(t)
        (f, t) = RacketCourtZoneRule.tap(5, from: f, to: t); XCTAssertNil(f)
    }

    func testCopyPerModeAndSport() {
        XCTAssertEqual(RacketDrillCopy.blockLine(measure: .longestRally, recording: .byUnit),
                       "Recording. Log your longest rally at the end of the block, or find rallies afterwards.")
        XCTAssertEqual(RacketDrillCopy.pausedLine(.badminton), "Nothing is recorded or counted while paused.")
        XCTAssertTrue(RacketDrillCopy.pausedLine(.tableTennis).hasPrefix("Picking up balls"))
        XCTAssertEqual(RacketDrillCopy.restCaption(next: 3, autoStart: true), "Block 3 starts by itself after this")
        XCTAssertEqual(RacketDrillCopy.statusText(.recording(seconds: 192)), "● Recording 03:12")
        XCTAssertEqual(RacketDrillCopy.logSource(scanFound: false), "You enter this")
        XCTAssertEqual(RacketDrillCopy.countdownLine(recording: .byUnit, firstOfRun: false),
                       "Recording and the block timer start at zero")
    }

    // MARK: - Review and progress

    private func block(_ rally: Int?, feel: RacketDrillFeel? = nil, sec: Double = 300) -> SetLog {
        var s = SetLog(durationSec: sec)
        s.longestRally = rally
        s.drillFeelRaw = feel?.rawValue
        s.completedAt = t0
        return s
    }

    func testReviewHeadlineNewBestAndBars() {
        let r = RacketDrillReview.make(sets: [block(18), block(20), block(25)], measure: .longestRally, last: 24, best: 24, log: nil)
        XCTAssertEqual(r.headline, "25 shots")
        XCTAssertEqual(r.lastTime, "Last time 24")
        XCTAssertTrue(r.newBest)
        XCTAssertEqual(r.bars.map(\.text), ["18", "20", "25"])
        XCTAssertEqual(r.bars.map(\.best), [false, false, true])
        XCTAssertEqual(r.blocksLine, "3 blocks · no video")
        XCTAssertFalse(RacketDrillReview.make(sets: [block(10)], measure: .longestRally, last: nil, best: 30, log: nil).newBest)
        XCTAssertEqual(RacketDrillReview.buckets([2, 6, 7, 12, 20]).map(\.count), [1, 2, 1, 1])
    }

    private func session(daysAgo: Int, rallies: [Int], feel: RacketDrillFeel? = nil) -> WorkoutSession {
        var ex = SessionExercise(exerciseId: "racket-drill-badminton", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                 sets: rallies.map { block($0, feel: feel) }, displayName: "Drive rally", kindRaw: nil)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.badminton.rawValue
        ex.racketModeRaw = RacketMode.drill.rawValue
        ex.drillMeasureRaw = RacketDrillMeasure.longestRally.rawValue
        let start = t0.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        return WorkoutSession(routineName: "Q", startedAt: start, completedAt: start.addingTimeInterval(3600), exercises: [ex])
    }

    func testTrendLastFiveSessionsBestAverageAndFeel() {
        let history = [session(daysAgo: 28, rallies: [17], feel: .hard), session(daysAgo: 21, rallies: [19], feel: .hard),
                       session(daysAgo: 14, rallies: [21], feel: .hard), session(daysAgo: 7, rallies: [24], feel: .aboutRight)]
        var today = history[0].exercises[0]
        today.sets = [block(20, feel: .aboutRight), block(25, feel: .aboutRight)]
        let s = RacketDrillTrend.summary(sport: .badminton, name: "Drive rally", measure: .longestRally, metric: .measure,
                                         history: history, today: today, now: t0)
        XCTAssertEqual(s.points.map(\.value), [17, 19, 21, 24, 25])
        XCTAssertEqual(s.points.last?.label, "Today")
        XCTAssertEqual(s.best, 25)
        XCTAssertEqual(s.average ?? 0, 21.2, accuracy: 0.001)
        XCTAssertEqual(s.sessions, 5)
        XCTAssertTrue(s.bestYet)
        XCTAssertEqual(RacketDrillTrend.feelLine(sport: .badminton, name: "Drive rally", history: history, today: today),
                       "Hard → About right over the last 3 sessions")
        XCTAssertEqual(RacketDrillTrend.number(21.2), "21.2")
        XCTAssertEqual(RacketDrillTrend.number(25), "25")
        XCTAssertFalse(RacketDrillHistory.isFirstTime(sport: .badminton, name: "drive RALLY", history: history))
        XCTAssertTrue(RacketDrillHistory.isFirstTime(sport: .badminton, name: "Low serve", history: history))
        XCTAssertEqual(RacketDrillHistory.lastValue(sport: .badminton, name: "Drive rally", measure: .longestRally, history: history), 24)
    }

    // MARK: - Split parts keep their own orientation

    func testEachPartIsFittedUprightWithItsOwnTransform() {
        let natural = CGSize(width: 1920, height: 1080)
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)   // a quarter turn
        XCTAssertEqual(RacketVideoOrientation.orientedSize(natural: natural, transform: portrait), CGSize(width: 1080, height: 1920))
        XCTAssertNotEqual(RacketVideoOrientation.key(portrait), RacketVideoOrientation.key(.identity))
        // A landscape part in a portrait render: fitted, centred, upright.
        let render = CGSize(width: 1080, height: 1920)
        let fitted = CGRect(origin: .zero, size: natural)
            .applying(RacketVideoOrientation.fit(natural: natural, transform: .identity, render: render))
        XCTAssertEqual(fitted.width, 1080, accuracy: 0.5)
        XCTAssertEqual(fitted.height, 607.5, accuracy: 0.5)
        XCTAssertEqual(fitted.midY, 960, accuracy: 0.5)
        // The portrait part fills the same render exactly.
        let p = CGRect(origin: .zero, size: natural).applying(RacketVideoOrientation.fit(natural: natural, transform: portrait, render: render))
        XCTAssertEqual(p.minX, 0, accuracy: 0.5); XCTAssertEqual(p.width, 1080, accuracy: 0.5); XCTAssertEqual(p.height, 1920, accuracy: 0.5)
        // Spans cover the whole timeline, gaps empty.
        let spans = RacketVideoOrientation.spans([.init(start: 0, duration: 10, key: "a"), .init(start: 15, duration: 5, key: "b")], total: 25)
        XCTAssertEqual(spans, [.init(start: 0, end: 10, key: "a"), .init(start: 10, end: 15, key: nil),
                               .init(start: 15, end: 20, key: "b"), .init(start: 20, end: 25, key: nil)])
    }
}
