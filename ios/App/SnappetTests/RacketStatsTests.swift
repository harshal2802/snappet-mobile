import XCTest
@testable import Snappet

/// Unit tests for the **pure** racket read model (prompt 203): entity accessors + Codable round-trip,
/// records / head-to-head, the session summary, titles, drills, Library headlines, and per-unit HR
/// windows. No device.
final class RacketStatsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(_ a: Int, _ b: Int, at sec: Double, duration: Double? = nil) -> SetLog {
        var s = SetLog(completedAt: t0.addingTimeInterval(sec), durationSec: duration)
        s.scoreFor = a; s.scoreAgainst = b
        return s
    }

    private func match(_ sport: RacketSport = .tableTennis, opponent: String? = "Alex Chen",
                       games: [SetLog] = [], bestOf: Int? = nil, round: String? = nil,
                       event: String? = nil) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(sport), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: games,
                                 displayName: RacketStats.matchActivityName(sport),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = sport.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = opponent
        ex.racketBestOf = bestOf
        ex.racketRound = round
        ex.racketEvent = event
        return ex
    }

    private func drill(_ name: String = "Short backspin serve", measure: RacketDrillMeasure = .madeTried,
                       blocks: [(Int, Int)] = []) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.drillExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0,
                                 sets: blocks.enumerated().map { i, b in
                                     var s = SetLog(completedAt: t0.addingTimeInterval(Double(i) * 200), durationSec: 180)
                                     s.drillMade = b.0; s.drillTried = b.1
                                     return s
                                 },
                                 displayName: name, kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.drill.rawValue
        ex.drillMeasureRaw = measure.rawValue
        return ex
    }

    private let won31 = [(11, 7), (9, 11), (12, 10), (11, 8)]

    private func wonMatch(_ opponent: String = "Alex Chen", round: String? = "R16") -> SessionExercise {
        match(opponent: opponent, games: won31.enumerated().map { i, g in game(g.0, g.1, at: Double(i + 1) * 400) },
              round: round, event: "City Open")
    }

    private func session(_ exercises: [SessionExercise], daysAgo: Double = 1) -> WorkoutSession {
        let s = WorkoutSession(routineName: "City Open", exercises: exercises)
        s.startedAt = t0.addingTimeInterval(-daysAgo * 86_400)
        s.completedAt = s.startedAt.addingTimeInterval(3600)
        return s
    }

    // MARK: - Model

    func testAccessorsAndDefaults() {
        let ex = match()
        XCTAssertEqual(ex.discipline, .racket)
        XCTAssertTrue(ex.isRacketMatch)
        XCTAssertEqual(ex.racketFormat, RacketFormat.defaults(for: .tableTennis))   // nil best-of ⇒ default
        var open = ex; open.racketBestOf = 0
        XCTAssertNil(open.racketFormat.bestOf)                                      // 0 ⇒ open play
        XCTAssertEqual(ex.racketMatchTitle, "vs Alex Chen")
        var doubles = ex; doubles.partner = "Mia"; doubles.opponent = "Jordan & Lee"
        XCTAssertEqual(doubles.racketMatchTitle, "You & Mia vs Jordan & Lee")
        XCTAssertEqual(drill().drillMeasure, .madeTried)
    }

    func testCodableRoundTripAndLegacyDecode() throws {
        let ex = wonMatch()
        let data = try JSONEncoder().encode(ex)
        let back = try JSONDecoder().decode(SessionExercise.self, from: data)
        XCTAssertEqual(back, ex)
        XCTAssertEqual(back.racketState.shortResult, "W 3–1")
        // A pre-racket blob has none of the new keys and decodes with nil racket fields.
        let legacy = SessionExercise(exerciseId: "bench", targetSets: 3, targetReps: "8", targetRestSeconds: 90,
                                     sets: [SetLog(actualReps: 8, actualWeight: 60, weightUnit: .kg)])
        let legacyJSON = String(data: try JSONEncoder().encode(legacy), encoding: .utf8)!
        XCTAssertFalse(legacyJSON.contains("racket"))
        XCTAssertFalse(legacyJSON.contains("scoreFor"))
        XCTAssertNil(try JSONDecoder().decode(SessionExercise.self, from: Data(legacyJSON.utf8)).racketSport)
    }

    // MARK: - Records

    func testRecordAndHeadToHead() {
        let lost = match(opponent: "alex chen ", games: [game(5, 11, at: 100), game(8, 11, at: 200), game(9, 11, at: 300)])
        let history = [session([wonMatch()], daysAgo: 7), session([lost], daysAgo: 3),
                       session([match(.badminton, opponent: "Alex Chen", games: [game(21, 10, at: 100), game(21, 12, at: 200)])])]
        let h2h = RacketStats.headToHead(opponent: "Alex Chen", sport: .tableTennis, history: history)
        XCTAssertEqual(h2h.won, 1); XCTAssertEqual(h2h.lost, 1)                   // badminton excluded, name normalized
        XCTAssertEqual(RacketStats.headToHead(opponent: nil, sport: .tableTennis, history: history).played, 0)
        // Unfinished matches don't count.
        XCTAssertEqual(RacketStats.record([match(games: [game(11, 3, at: 10)])]).played, 0)
    }

    func testRecentOpponentsAndEvents() {
        let history = [session([wonMatch("Sam")], daysAgo: 5), session([wonMatch("Priya"), wonMatch("sam")], daysAgo: 1)]
        XCTAssertEqual(RacketStats.recentOpponents(sport: .tableTennis, history: history), ["sam", "Priya"])
        XCTAssertEqual(RacketStats.recentEvents(history: history), ["City Open"])
    }

    // MARK: - Summary & titles

    func testSessionSummaryAndTitles() {
        let lost = match(opponent: "Priya", games: [game(7, 11, at: 100), game(11, 9, at: 200), game(8, 11, at: 300), game(6, 11, at: 400)], round: "QF")
        let ex = [wonMatch("Sam", round: "R32"), wonMatch(), lost, drill(blocks: [(33, 50)])]
        let sum = RacketStats.summary(ex)!
        XCTAssertEqual(sum.record.label, "2W – 1L")
        XCTAssertEqual(sum.matches, 3)
        XCTAssertEqual(sum.units, 12)
        XCTAssertEqual(sum.drills, 1)
        XCTAssertEqual(sum.event, "City Open")
        XCTAssertNil(RacketStats.summary([]))
        XCTAssertEqual(RacketStats.postTitle(wonMatch()), "R16 vs Alex Chen · Won 3–1")
        XCTAssertEqual(RacketStats.postTitle(lost), "QF vs Priya · Lost 1–3")
        XCTAssertEqual(RacketStats.postTitle(match(games: [game(11, 4, at: 10)])), "vs Alex Chen · 1–0")
        XCTAssertEqual(RacketStats.postSubtitle(wonMatch()), "City Open · Table tennis · 11–7  9–11  12–10  11–8")
        XCTAssertEqual(RacketStats.matchRowTitle(wonMatch()), "R16 · vs Alex Chen")
    }

    // MARK: - Drills & Library

    func testDrillLinesAndHeadline() {
        let d = drill(blocks: [(33, 50), (36, 50), (38, 50)])
        XCTAssertEqual(RacketStats.drillLine(d), "107/150 · 71%")
        XCTAssertEqual(RacketStats.blockLine(d.sets[2], measure: .madeTried), "38/50 76% 3:00")
        XCTAssertEqual(RacketStats.headline([d]).0, "76%")
        XCTAssertEqual(RacketStats.postTitle(d), "Short backspin serve · 107/150 · 71%")
        var rally = drill("Forehand loop vs block", measure: .longestRally)
        var s = SetLog(completedAt: t0); s.longestRally = 42
        rally.sets = [s]
        XCTAssertEqual(RacketStats.drillLine(rally), "rally 42")
        XCTAssertEqual(RacketStats.headline([wonMatch(), wonMatch("Sam")]).0, "2W – 0L")
        XCTAssertEqual(RacketStats.lastLine(wonMatch()), "W 3–1 vs Alex Chen")
    }

    func testRecentDrills() {
        let history = [session([drill("Serve", blocks: [(1, 2)])], daysAgo: 4),
                       session([drill("Loop", measure: .longestRally), drill("serve")], daysAgo: 1)]
        let names = RacketStats.recentDrills(sport: .tableTennis, history: history).map(\.name)
        XCTAssertEqual(names, ["Loop", "serve"])
    }

    // MARK: - Per-unit windows & HR

    func testUnitWindows() {
        let ex = match(games: [game(11, 7, at: 700, duration: 300), game(9, 11, at: 1300), game(11, 5, at: 1500)])
        let w = RacketStats.unitWindows(ex, sessionStart: t0)
        XCTAssertEqual(w.map(\.start), [400, 700, 1300])   // timed → its duration; untimed → previous end
        XCTAssertEqual(w.map(\.end), [700, 1300, 1500])
        let first = RacketStats.unitWindows(match(games: [game(11, 7, at: 200)]), sessionStart: t0)
        XCTAssertEqual(first.first?.start, 0)              // fallback clipped to the session start
    }

    func testUnitHR() {
        let ex = match(games: [game(11, 7, at: 100, duration: 100), game(9, 11, at: 200, duration: 100)])
        let series = stride(from: 0.0, through: 200, by: 10).map { HRPoint(t: $0, bpm: $0 < 100 ? 130 : 170) }
        let hr = RacketStats.unitHR(ex, series: series, sessionStart: t0, maxHR: 190)
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr[0].peak, 170)                    // the boundary sample belongs to both windows
        XCTAssertGreaterThan(hr[1].avg, hr[0].avg)
        XCTAssertEqual(hr[1].zoneSeconds.count, 5)
    }

    // MARK: - Integration with shared reads

    func testPagerAndSummaryIntegration() {
        let inPlay = match(games: [game(11, 7, at: 100)])
        XCTAssertTrue(QuickSessionPager.isUnfinished(inPlay))
        XCTAssertFalse(QuickSessionPager.isUnfinished(wonMatch()))
        XCTAssertNil(QuickSessionPager.planState(for: inPlay))
        XCTAssertEqual(QuickSessionPager.effortNoun(for: inPlay), "game")
        XCTAssertEqual(QuickSessionPager.effortNoun(for: match(.tennis)), "set")
        XCTAssertEqual(QuickSessionPager.effortNoun(for: drill()), "block")
        XCTAssertEqual(QuickSessionPager.recordTitle(for: inPlay), "Record a game")
        XCTAssertFalse(QuickSessionPager.startsRestAfterLog(inPlay))
        let chips = QuickSessionPager.railChips(for: [wonMatch()]) { _ in "Table tennis match" }
        XCTAssertEqual(chips[1].title, "Alex")
        XCTAssertEqual(chips[1].detail, "W 3–1")
        XCTAssertEqual(chips[1].symbol, "figure.table.tennis")
        let s = session([wonMatch(), wonMatch("Sam")])
        XCTAssertEqual(FreeformSummary.dominant(for: s), .racket)
        XCTAssertEqual(FreeformSummary.stats(for: s, unit: .kg).headline.value, "2–0")
        XCTAssertEqual(FreeformSummary.holdTimeSeconds(session([match(games: [game(11, 3, at: 50, duration: 300)])])), 0)
    }

    func testActivityTypeAndClipActivity() {
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .tableTennis), .tableTennis)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .padel), .tennis)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: wonMatch()), .tableTennis)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: WorkoutDiscipline.racket), .other)
        XCTAssertEqual(HealthKitService.label(.tableTennis), "Table Tennis")
        XCTAssertEqual(ClipActivity.forImportLabel("Table Tennis"), .racket)
        XCTAssertEqual(ClipActivity.forExercise(.racket), .racket)
    }

    func testLibraryCatalogAndDashboard() {
        let history = [session([wonMatch()], daysAgo: 9), session([wonMatch("Sam")], daysAgo: 2)]
        let key = ActivityKey.plain(wonMatch())!
        let ids = ActivityIdentity(sessions: history)
        XCTAssertTrue(ids.matches(key, wonMatch("Someone else")))   // a match's activity is its sport
        let dash = ActivityDashboard.make(key: key, history: history, media: [], unit: .kg, now: t0, identity: ids)!
        XCTAssertEqual(dash.metric, .winRate)
        XCTAssertEqual(dash.points.map(\.label), ["100%", "100%"])
        XCTAssertTrue(dash.records.contains { $0.title == "Record" && $0.value == "2W – 0L" })
        XCTAssertEqual(LibraryCatalog.lastLine(wonMatch(), unit: .kg, distanceUnit: .km), "W 3–1 vs Alex Chen")
    }

    func testLaunchClearsOpponent() {
        let history = [session([wonMatch()], daysAgo: 1)]
        let ids = ActivityIdentity(sessions: history)
        let key = ActivityKey.plain(wonMatch())!
        let fresh = ActivityLauncher.sessionExercise(for: key, history: history, identity: ids)!
        XCTAssertNil(fresh.opponent)
        XCTAssertNil(fresh.racketRound)
        XCTAssertEqual(fresh.racketEvent, "City Open")
        XCTAssertTrue(fresh.sets.isEmpty)
        XCTAssertNil(ActivityLauncher.routineBlock(for: key, history: history, identity: ids, defaultUnit: .kg))
    }
}
