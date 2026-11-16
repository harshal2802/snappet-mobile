import XCTest
@testable import Snappet
import HighlightEngine

/// Prompt 259: a game joined across a timeout (prompt 258) takes its heart-rate window from its real stretches — the
/// first half's start to the last half's end — and leaves the timeout out of its averages, peak, zone time and HRV.
/// Recordings without an applied split (or a game without a timeout) keep the window they had.
final class RacketJoinedGameHRTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A match whose recording starts 100 s into the session: game 1 [0, 300] + timeout [300, 420] + game 1 continued
    /// [420, 600] (recording time), then game 2 [600, 900]. Game 1's duration is its played time, 480 s.
    private func match(split applied: Bool = true, timeout: Bool = true) -> SessionExercise {
        var g1 = SetLog(completedAt: t0.addingTimeInterval(100 + 600), durationSec: 480)
        g1.scoreFor = 11; g1.scoreAgainst = 8
        var g2 = SetLog(completedAt: t0.addingTimeInterval(100 + 900), durationSec: 300)
        g2.scoreFor = 7; g2.scoreAgainst = 11
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [g1, g2],
                                 displayName: RacketStats.matchActivityName(.tableTennis),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        var log = RacketRecordingLog(startedAt: t0.addingTimeInterval(100))
        let parts: [RacketVideoPart] = [
            .init(kind: .game, startSec: 0, endSec: 300, setIndex: 0),
            .init(kind: timeout ? .timeout : .breakTime, startSec: 300, endSec: 420),
            .init(kind: .game, startSec: 420, endSec: 600, setIndex: timeout ? nil : 1),
            .init(kind: .game, startSec: 600, endSec: 900, setIndex: timeout ? 1 : nil),
        ]
        log.split = RacketSplit(parts: parts, appliedAt: applied ? t0.addingTimeInterval(1000) : nil)
        ex.racketRecordingLog = log
        return ex
    }

    /// 150 bpm while playing, 100 bpm in the timeout (session seconds 400…520), a reading every 5 s.
    private var series: [HRPoint] {
        stride(from: 0.0, through: 1000, by: 5).map { HRPoint(t: $0, bpm: ($0 > 400 && $0 < 520) ? 100 : 150) }
    }

    func testJoinedGameWindowIsItsRealStretches() {
        let w = RacketStats.unitWindows(match(), sessionStart: t0)
        XCTAssertEqual(w[0].start, 100, "from the first half's start (not completedAt − played time = 220)")
        XCTAssertEqual(w[0].end, 700, "to the last half's end")
        XCTAssertEqual(w[0].gaps, [400...520], "the timeout, on the session timeline")
        XCTAssertEqual(w[1], RacketStats.UnitWindow(index: 1, start: 700, end: 1000), "a plain game is as before")
    }

    func testFallsBackWithoutTheSplitsTimes() {
        // Split not applied, or no timeout: today's window (completedAt − duration … completedAt), nothing left out.
        for ex in [match(split: false), match(timeout: false)] {
            let w = RacketStats.unitWindows(ex, sessionStart: t0)
            XCTAssertEqual(w[0], RacketStats.UnitWindow(index: 0, start: 220, end: 700))
        }
        var none = match()
        none.racketRecordingLog = nil
        XCTAssertEqual(RacketStats.unitWindows(none, sessionStart: t0)[0], RacketStats.UnitWindow(index: 0, start: 220, end: 700))
    }

    func testPlayedMoments() {
        let w = RacketStats.UnitWindow(index: 0, start: 100, end: 700, gaps: [400...520])
        XCTAssertTrue(w.plays(100)); XCTAssertTrue(w.plays(400), "a timeout's edge is play"); XCTAssertTrue(w.plays(520))
        XCTAssertFalse(w.plays(450)); XCTAssertFalse(w.plays(99)); XCTAssertFalse(w.plays(701))
        XCTAssertEqual(w.played(100, 700), 480)
        XCTAssertEqual(w.played(390, 530), 20)
        XCTAssertEqual(w.played(450, 460), 0)
        XCTAssertEqual(w.played(500, 400), 0)
    }

    func testAveragesAndZonesLeaveTheTimeoutOut() {
        let hr = RacketStats.unitHR(match(), series: series, sessionStart: t0, maxHR: 190)
        XCTAssertEqual(hr[0].avg, 150, "the timeout's 100 bpm readings are left out")
        XCTAssertEqual(hr[0].peak, 150)
        XCTAssertEqual(hr[0].zoneSeconds.reduce(0, +), 480, accuracy: 0.001, "zone time is played time")
        // Today's window for the same game took the timeout in.
        let old = RacketStats.unitHR(match(split: false), series: series, sessionStart: t0, maxHR: 190)
        XCTAssertLessThan(old[0].avg, 150)
    }

    func testGameSheetShowsTheTimeoutOnItsTimeline() {
        let g = RacketStats.games(match(), series: series, sessionStart: t0, maxHR: 190)[0]
        XCTAssertEqual(g.start, 100)
        XCTAssertEqual(g.duration, 600, "the chart spans the whole stretch")
        XCTAssertEqual(g.playedSec, 480)
        XCTAssertEqual(g.timeouts, [300...420], "on the game's timeline")
        XCTAssertTrue(g.points.contains { $0.bpm == 100 }, "the timeout's readings are drawn (shaded), not hidden")
        XCTAssertEqual(g.avg, 150)
        XCTAssertEqual(RacketGameHRSheet.timeoutNote(g), ["1 timeout left out"])
        let plain = RacketStats.games(match(), series: series, sessionStart: t0, maxHR: 190)[1]
        XCTAssertEqual(plain.timeouts, [])
        XCTAssertEqual(RacketGameHRSheet.timeoutNote(plain), [])
    }

    func testHRVLeavesTheTimeoutOut() {
        // Beat-to-beat data: steady 400 ms in play, wildly varying in the timeout.
        let samples = stride(from: 0.0, through: 1000, by: 1).map { t -> HRPoint in
            let inTimeout = t > 400 && t < 520
            return HRPoint(t: t, bpm: 150, rrIntervalsMs: inTimeout ? [300, 900] : [400, 400])
        }
        let g = RacketStats.games(match(), series: samples, sessionStart: t0, maxHR: 190)[0]
        XCTAssertEqual(g.hrv.rmssd ?? -1, 0, accuracy: 0.5, "only play's steady beats count")
        let ex = match()
        let reads = HRVReads.perSet(for: [ex], sessionStart: t0,
                                    hr: samples.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) })
        XCTAssertEqual(reads[.init(exerciseID: ex.id, setIndex: 0)]?.rmssd ?? -1, 0, accuracy: 0.5)
    }
}
