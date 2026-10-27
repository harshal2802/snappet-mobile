import XCTest
@testable import Snappet
import HighlightEngine

/// HRV on every heart-rate surface (2026-10-26): only RR from a chest strap produces a figure; everything else
/// (a Fitbit over Bluetooth, an Apple Watch, a Health back-fill) stays empty so the views hide.
final class HRVReadsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// 1 Hz samples whose RR alternates `a`/`b` ms — RMSSD = |a − b|.
    private func strap(from: Double, to: Double, a: Double, b: Double) -> [HRSample] {
        stride(from: from, to: to, by: 1).map { t in
            HRSample(t: t, bpm: 120, rrIntervalsMs: [a, b])
        }
    }

    private func game(_ a: Int, _ b: Int, at sec: Double) -> SetLog {
        var s = SetLog(completedAt: t0.addingTimeInterval(sec)); s.scoreFor = a; s.scoreAgainst = b
        return s
    }

    private func match(_ games: [SetLog]) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: games,
                                 displayName: RacketStats.matchActivityName(.tableTennis),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        return ex
    }

    func testRollingUsesOnlyTheLastMinute() {
        let samples = strap(from: 0, to: 120, a: 800, b: 900) + strap(from: 120, to: 200, a: 600, b: 620)
        XCTAssertEqual(HRVReads.rolling(samples).rmssd ?? 0, 20, accuracy: 0.5)
        XCTAssertNil(HRVReads.rolling([]).rmssd)
    }

    func testNoRRMeansNoHRVAnywhere() {
        let bpmOnly = stride(from: 0.0, to: 600, by: 1).map { HRSample(t: $0, bpm: 150) }
        XCTAssertNil(HRVReads.rolling(bpmOnly).rmssd, "a Fitbit / Apple Watch stream has no beat-to-beat timing")
        XCTAssertNil(HRVReads.session(WorkoutHRStats.points(from: bpmOnly)).rmssd)
        XCTAssertTrue(HRVReads.perSet(for: [match([game(11, 7, at: 300)])], sessionStart: t0, hr: bpmOnly).isEmpty)
    }

    func testEachGameGetsItsOwnWindowsHRV() {
        let ex = match([game(11, 7, at: 300), game(9, 11, at: 600)])
        let hr = strap(from: 0, to: 300, a: 700, b: 760) + strap(from: 300, to: 601, a: 500, b: 510)
        let per = HRVReads.perSet(for: [ex], sessionStart: t0, hr: hr)
        XCTAssertEqual(per[.init(exerciseID: ex.id, setIndex: 1)]?.rmssd ?? 0, 10, accuracy: 1.5)
        XCTAssertEqual(HRVReads.session(WorkoutHRStats.points(from: hr)).beatCount, 1202)

        let games = RacketStats.games(ex, series: WorkoutHRStats.points(from: hr), sessionStart: t0, maxHR: 190)
        XCTAssertEqual(games.count, 2)
        XCTAssertEqual(games[1].points.first?.t, 0, "points are on the game's own timeline")
        XCTAssertFalse(games[1].isSparse)
        let line = RacketStats.comparison(games[1], previous: games[0], unit: .game)
        XCTAssertTrue(line?.contains("vs game 1") ?? false)
        XCTAssertTrue(line?.contains("HRV −") ?? false, "lower HRV than game 1: \(line ?? "nil")")
    }

    func testSparseHealthReadingsAreFlagged() {
        let ex = match([game(9, 11, at: 260)])
        let health = stride(from: 0.0, to: 260, by: 26).map { HRPoint(t: $0, bpm: 170) }
        let g = RacketStats.games(ex, series: health, sessionStart: t0, maxHR: 184)[0]
        XCTAssertTrue(g.isSparse)
        XCTAssertNil(g.hrv.rmssd)
        XCTAssertNil(RacketStats.comparison(g, previous: nil, unit: .game))
    }

    func testDashboardTrendNeedsTwoStrapSessions() {
        func session(daysAgo: Double, gap: Double, rr: Bool = true) -> WorkoutSession {
            let start = t0.addingTimeInterval(-daysAgo * 86_400)
            var ex = match([])
            for end in [300.0, 600.0] { var g = SetLog(completedAt: start.addingTimeInterval(end)); g.scoreFor = 11; g.scoreAgainst = 5; ex.sets.append(g) }
            let s = WorkoutSession(routineID: nil, routineName: "Club night", exercises: [ex])
            s.startedAt = start; s.completedAt = start.addingTimeInterval(610)
            s.hrSeries = stride(from: 0.0, through: 610, by: 1).map {
                HRPoint(t: $0, bpm: 140, rrIntervalsMs: rr ? [600, 600 + gap] : nil)
            }
            return s
        }
        let key = ActivityKey.plain(match([]))!
        XCTAssertNil(ActivityInsights.hrv(key: key, history: [session(daysAgo: 3, gap: 30)]), "one session isn't a trend")
        XCTAssertNil(ActivityInsights.hrv(key: key, history: [session(daysAgo: 3, gap: 30, rr: false),
                                                              session(daysAgo: 1, gap: 20, rr: false)]),
                     "no chest strap → no card")
        let pts = ActivityInsights.hrv(key: key, history: [session(daysAgo: 1, gap: 20), session(daysAgo: 3, gap: 30)])
        XCTAssertEqual(pts?.map { Int($0.rmssd.rounded()) }, [30, 20], "oldest first")
    }
}
