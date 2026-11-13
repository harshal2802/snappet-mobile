import XCTest
@testable import Snappet

/// Unit tests for the sport-specific rules from the boards (prompt 252, issue #438 parity, the last batch): pickleball
/// side-out scoring and its call (PbScoring / PbSideOut / PbWatch / PbTag), tennis No-ad, who serves by name in doubles
/// for every sport, the tag sheet's sport lines, TnServe / PdWall / SqLet, and the Watch wire. No device.
final class RacketSportRulesTests: XCTestCase {

    private typealias S = RacketLiveScore.Side

    private func pts(_ s: String) -> [S] { s.map { $0 == "u" ? .us : .them } }

    private func sideOut(doubles: Bool = true, first: S = .us, to: Int = 11) -> RacketLiveRules {
        RacketLiveRules(kind: .rally, pointsTo: to, sideOut: true, doubles: doubles, servesFirst: first)
    }

    private func match(_ sport: RacketSport, partner: String? = nil, sideOut: Bool? = nil, golden: Bool? = nil,
                       first: RacketServe.Side? = nil, ours: RacketDoublesServe.Player? = nil,
                       games: [SetLog] = []) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(sport), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: games, displayName: RacketStats.matchActivityName(sport),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = sport.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = partner == nil ? "Alex Chen" : "Jordan & Lee"
        ex.partner = partner
        ex.racketSideOut = sideOut
        ex.racketGoldenPoint = golden
        ex.racketFirstServerRaw = first?.rawValue
        ex.racketOurFirstServerRaw = ours?.rawValue
        return ex
    }

    private func set(_ f: Int, _ a: Int) -> SetLog {
        var s = SetLog()
        s.scoreFor = f
        s.scoreAgainst = a
        return s
    }

    // MARK: - Side-out tally (Shared/RacketLiveScore)

    func testDoublesSideOutStartsOnServerTwoAndOnlyTheServingSideScores() {
        var s = RacketLiveScore(rules: sideOut())
        XCTAssertEqual(s.display, "0–0–2", "the game's first side has one server")
        XCTAssertEqual(s.tally.serving, .us)
        s.point(.us)
        XCTAssertEqual(s.display, "1–0–2", "the serving side scores")
        s.point(.them)
        XCTAssertEqual(s.display, "0–1–1", "the start's one server lost: side-out to their server 1; call from their side")
        XCTAssertEqual(s.tally.serving, .them)
        XCTAssertEqual([s.tally.pointsFor, s.tally.pointsAgainst], [1, 0], "no point for winning while receiving")
        s.point(.us)
        XCTAssertEqual(s.display, "0–1–2", "their server 1 lost: no point, their server 2")
        XCTAssertEqual([s.tally.pointsFor, s.tally.pointsAgainst], [1, 0])
        s.point(.them)
        XCTAssertEqual(s.display, "1–1–2", "their server 2 won: a point, same server")
        s.point(.us)
        XCTAssertEqual(s.display, "1–1–1", "side-out back to us, server 1")
        XCTAssertEqual(s.tally.serving, .us)
    }

    func testServerOneThenServerTwoLosingIsTheSideOutBoard() {
        // PbSideOut: 4–2 serving, server 1 loses → "4 – 2 – 2"; server 2 loses → side-out "2 – 4 – 1".
        var b = RacketLiveScore(rules: sideOut())
        for p in pts("uuuu") { b.point(p) }                      // 4–0–2
        b.point(.them)                                            // side-out: them serve 0–4–1
        b.point(.them); b.point(.them)                            // 2–4–1
        b.point(.us)                                              // their server 2: 2–4–2
        b.point(.us)                                              // side-out to us, server 1: 4–2–1
        XCTAssertEqual(b.display, "4–2–1")
        XCTAssertTrue(b.tally.serveChanges.last?.sideOut == true, "the last change was the side-out to us")
        b.point(.them)
        XCTAssertEqual(b.display, "4–2–2")
        XCTAssertEqual(b.tally.serveChanges, [.init(side: .us, serverNumber: 1, sideOut: false, callAfter: "4 – 2 – 2")])
        b.point(.them)
        XCTAssertEqual(b.display, "2–4–1")
        XCTAssertEqual(b.tally.serveChanges, [.init(side: .us, serverNumber: 1, sideOut: false, callAfter: "4 – 2 – 2"),
                                              .init(side: .us, serverNumber: 2, sideOut: true, callAfter: "2 – 4 – 1")])
        b.point(.them)
        XCTAssertEqual(b.tally.serveChanges, [], "a point clears the panel")
    }

    func testAChangeChainStartsOverForTheNewServingSide() {
        var b = RacketLiveScore(rules: sideOut())
        b.point(.them)                       // our one server lost: side-out
        XCTAssertEqual(b.tally.serveChanges.count, 1)
        b.point(.us)                         // their server 1 lost
        XCTAssertEqual(b.tally.serveChanges, [.init(side: .them, serverNumber: 1, sideOut: false, callAfter: "0 – 0 – 2")])
    }

    func testSinglesSideOutHasNoServerNumber() {
        var s = RacketLiveScore(rules: sideOut(doubles: false))
        XCTAssertEqual(s.display, "0–0")
        s.point(.us)
        XCTAssertEqual(s.display, "1–0")
        s.point(.them)
        XCTAssertEqual(s.display, "0–1", "singles: a lost serve is a side-out at once")
        XCTAssertEqual(s.tally.serving, .them)
        XCTAssertNil(s.tally.serverNumber)
    }

    func testASideOutGameEndsOnServeAtElevenWinByTwo() {
        var s = RacketLiveScore(rules: sideOut(doubles: false))
        for _ in 0..<10 { s.point(.us) }
        for _ in 0..<2 { s.point(.them) }         // side-out, them 1
        for _ in 0..<9 { s.point(.them) }         // them 10
        XCTAssertEqual([s.tally.pointsFor, s.tally.pointsAgainst], [10, 10])
        s.point(.them)
        XCTAssertFalse(s.isFinished, "11–10 isn't two clear")
        s.point(.them)
        XCTAssertEqual(s.result, RacketLiveUnitResult(scoreFor: 10, scoreAgainst: 12))
        XCTAssertFalse(s.point(.us), "decided")
        XCTAssertEqual(s.display, "10 – 12", "a decided game shows the final score from your side")
    }

    func testUndoDropsTheLastRallyIncludingAServeChange() {
        var s = RacketLiveScore(rules: sideOut(), points: pts("uut"))
        XCTAssertEqual(s.display, "0–2–1")
        s.undo()
        XCTAssertEqual(s.display, "2–0–2")
    }

    func testRallyScoringAndOtherSportsAreUnchanged() {
        let r = RacketLiveRules(kind: .rally, pointsTo: 11)
        XCTAssertNil(r.sideOut)
        XCTAssertNil(r.servesFirst)
        let s = RacketLiveScore(rules: r, points: pts("uut"))
        XCTAssertEqual(s.display, "2 – 1")
        XCTAssertNil(s.tally.serving)
        // Side-out is a rally-kind option only.
        XCTAssertNil(RacketLiveRules(kind: .sets, pointsTo: 6, sideOut: true).sideOut)
    }

    func testHeaderAndButtonsFollowPbWatch() {
        let s = RacketLiveScore(rules: sideOut())
        XCTAssertEqual(s.header(unitNumber: 1), "Game 1 · you serve")
        XCTAssertEqual(RacketLiveScore(rules: sideOut(first: .them)).header(unitNumber: 2), "Game 2 · they serve")
        XCTAssertEqual(sideOut().scoreButtons(us: "Us", them: "Them").us, "We won")
        XCTAssertEqual(sideOut().scoreButtons(us: "Us", them: "Them").them, "They won")
        XCTAssertEqual(sideOut(doubles: false).scoreButtons(us: "You", them: "Alex").them, "Alex won")
        XCTAssertEqual(RacketLiveRules(kind: .rally, pointsTo: 11).scoreButtons(us: "You", them: "Alex").us, "You +1")
    }

    func testRulesTravelOnTheWireAndOldPayloadsReadAsRallyScoring() throws {
        let r = sideOut(first: .them)
        let back = try JSONDecoder().decode(RacketLiveRules.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        let old = Data(#"{"kind":"rally","pointsTo":11,"superTiebreak":false}"#.utf8)
        let decoded = try JSONDecoder().decode(RacketLiveRules.self, from: old)
        XCTAssertFalse(decoded.isSideOut)
        let state = RacketWatchState(sessionID: UUID(), revision: 3, sport: "Pickleball", unitNoun: "game", sideUs: "Us",
                                     sideThem: "Them", note: "Winning while receiving doesn’t score",
                                     surface: .scoring(.init(unitNumber: 1, score: RacketLiveScore(rules: r, points: pts("tu")),
                                                             clock: .init(base: 0, asOf: Date(timeIntervalSince1970: 0),
                                                                          running: true), matchLine: nil)),
                                     stillPlaying: nil, notice: nil)
        XCTAssertEqual(RacketWatchMessage(payload: RacketWatchMessage.state(state).payload), .state(state))
    }

    // MARK: - Format, rules for a unit, the match form

    func testPickleballFormatAndRulesPerGame() {
        XCTAssertTrue(RacketFormat(sport: .pickleball, bestOf: 3, sideOut: true).sideOut)
        XCTAssertFalse(RacketFormat(sport: .badminton, bestOf: 3, sideOut: true).sideOut, "pickleball only")
        let ex = match(.pickleball, partner: "Mia", sideOut: true, first: .them)
        let g1 = ex.racketLiveRules(unitIndex: 0)
        XCTAssertTrue(g1.isSideOut)
        XCTAssertEqual(g1.doubles, true)
        XCTAssertEqual(g1.servesFirst, .them)
        XCTAssertEqual(ex.racketLiveRules(unitIndex: 1).servesFirst, .us, "the side that received first serves first next")
        XCTAssertEqual(ex.racketLiveRules(unitIndex: 2).servesFirst, .them)
        XCTAssertEqual(ex.racketLiveRules(unitIndex: 0, firstServer: .some(.us)).servesFirst, .us, "warmup override")
        XCTAssertEqual(match(.pickleball, sideOut: true).racketLiveRules(unitIndex: 0).servesFirst, .us,
                       "nobody said: you serve first (the call needs a server)")
        XCTAssertNil(match(.pickleball, sideOut: true).racketLiveRules(unitIndex: 0).doubles)
        XCTAssertFalse(match(.pickleball).racketLiveRules(unitIndex: 0).isSideOut, "older matches keep rally scoring")
    }

    func testMatchParamsWriteSideOutAndNoAd() {
        var p = RacketMatchParams(sport: .pickleball)
        XCTAssertTrue(p.sideOut, "PbScoring opens on Traditional, side-out")
        var ex = match(.pickleball)
        p.apply(to: &ex)
        XCTAssertEqual(ex.racketSideOut, true)
        p.sideOut = false
        p.apply(to: &ex)
        XCTAssertNil(ex.racketSideOut)
        XCTAssertFalse(RacketMatchParams(sport: .tennis).sideOut)
        var t = RacketMatchParams(sport: .tennis)
        t.goldenPoint = true
        var tex = match(.tennis)
        t.apply(to: &tex)
        XCTAssertEqual(tex.racketGoldenPoint, true, "tennis No-ad shares the deciding-point field")
        XCTAssertTrue(tex.racketFormat.noAd)
        XCTAssertTrue(RacketMatchParams(from: tex).goldenPoint)
        XCTAssertFalse(RacketFormat(sport: .padel, bestOf: 3, goldenPoint: true).noAd, "padel calls it Golden point")
    }

    // MARK: - Tennis No-ad

    func testNoAdDeuceIsDecidedByTheNextPointAndTiebreaksAreUnchanged() {
        let rules = RacketLiveRules(format: RacketFormat(sport: .tennis, bestOf: 3, goldenPoint: true), unitIndex: 0)
        XCTAssertEqual(rules.goldenPoint, true)
        var s = RacketLiveScore(rules: rules, points: pts("uuuttt"))
        XCTAssertEqual(s.display, "40 – 40")
        s.point(.them)
        XCTAssertEqual([s.tally.gamesFor, s.tally.gamesAgainst], [0, 1], "no-ad: 40–40 then one point wins the game")
        // With advantage, 4–3 is only Ad.
        let adv = RacketLiveScore(rules: RacketLiveRules(format: RacketFormat(sport: .tennis, bestOf: 3), unitIndex: 0),
                                  points: pts("uuuttt") + [.them])
        XCTAssertEqual(adv.display, "40 – Ad")
        // 6–6 → tiebreak to 7, win by 2: no-ad doesn't touch it.
        let game = pts("uuuu"), lost = pts("tttt")
        var all: [S] = []
        for _ in 0..<6 { all += game + lost }
        var tb = RacketLiveScore(rules: rules, points: all)
        XCTAssertTrue(tb.tally.inTiebreak)
        for p in pts("uuuuuuttttttu") { tb.point(p) }    // 7–6 in the tiebreak
        XCTAssertFalse(tb.isFinished, "7–6 in a tiebreak isn't two clear, no-ad or not")
        tb.point(.us)
        XCTAssertEqual(tb.result, RacketLiveUnitResult(scoreFor: 7, scoreAgainst: 6, tiebreakFor: 8, tiebreakAgainst: 6))
    }

    func testTheServerChangesAfterANoAdGameAndASuperTiebreakServesOneThenTwo() {
        let ex = match(.tennis, golden: true, first: .us)
        let r = ex.racketLiveRules(unitIndex: 0)
        let deuce = pts("uuuttt")
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], points: deuce, rules: r), .us)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [],
                                          points: deuce + [.them], rules: r), .them, "the no-ad point ended the game")
        // A deciding super tiebreak: the next server serves one, then two each.
        let stb = RacketLiveRules(kind: .sets, pointsTo: 6, superTiebreak: true)
        let prev = [RacketUnitScore(scoreFor: 6, scoreAgainst: 4), RacketUnitScore(scoreFor: 4, scoreAgainst: 6)]
        let first = RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 2, previous: prev, points: [], rules: stb)
        XCTAssertEqual(first, .us, "20 games played: the first server's side")
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 2, previous: prev, points: pts("u"), rules: stb), .them)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 2, previous: prev, points: pts("ut"), rules: stb), .them)
        XCTAssertEqual(RacketServe.server(sport: .tennis, firstServer: .us, unitIndex: 2, previous: prev, points: pts("utu"), rules: stb), .us)
    }

    func testSideOutServerComesFromTheTally() {
        let r = sideOut()
        XCTAssertEqual(RacketServe.server(sport: .pickleball, firstServer: nil, unitIndex: 0, previous: [], points: [], rules: r), .us)
        XCTAssertEqual(RacketServe.server(sport: .pickleball, firstServer: nil, unitIndex: 0, previous: [], points: pts("t"), rules: r), .them)
        XCTAssertEqual(RacketServe.server(sport: .pickleball, firstServer: nil, unitIndex: 0, previous: [], points: pts("tu"), rules: r),
                       .them, "their server 1 lost: still them, server 2")
    }

    // MARK: - Doubles: who serves, by name

    private func info(_ sport: RacketSport, rules: RacketLiveRules, first: RacketServe.Side?, ours: RacketDoublesServe.Player?,
                      unit: Int = 0, previous: [RacketUnitScore] = [], _ p: String) -> RacketDoublesServe.Info? {
        RacketDoublesServe.info(sport: sport, rules: rules, firstServer: first, ourFirst: ours, unitIndex: unit,
                                previous: previous, points: pts(p), doubles: true)
    }

    func testTennisDoublesRotatesYourTwoServersAcrossTheMatch() {
        let r = RacketLiveRules(kind: .sets, pointsTo: 6)
        let g = "uuuu"   // a game we win
        XCTAssertEqual(info(.tennis, rules: r, first: .us, ours: .partner, "")?.player, .partner, "game 1: your first server")
        XCTAssertNil(info(.tennis, rules: r, first: .us, ours: .partner, g)?.player, "game 2: theirs, not named")
        XCTAssertEqual(info(.tennis, rules: r, first: .us, ours: .partner, g)?.side, .them)
        XCTAssertEqual(info(.tennis, rules: r, first: .us, ours: .partner, g + g)?.player, .you, "game 3: your second server")
        XCTAssertEqual(info(.tennis, rules: r, first: .us, ours: .partner, g + g + g + g)?.player, .partner, "game 5")
        // They serve first: your first service game is game 2.
        XCTAssertEqual(info(.tennis, rules: r, first: .them, ours: .you, g)?.player, .you)
        XCTAssertEqual(info(.tennis, rules: r, first: .them, ours: .you, g + g + g)?.player, .partner)
        // Set 2 after 6–4 (10 games): game 11 is the first server's side, A1 again? 10 games ⇒ rotation 10 ⇒ your 5th
        // service game ⇒ your first server's... r = 10, (10 / 2) % 2 = 1 ⇒ your second server.
        XCTAssertEqual(info(.tennis, rules: r, first: .us, ours: .partner, unit: 1,
                            previous: [RacketUnitScore(scoreFor: 6, scoreAgainst: 4)], "")?.player, .you)
        // Padel too; no first server ⇒ nothing known.
        XCTAssertEqual(info(.padel, rules: r, first: .us, ours: .you, "")?.player, .you)
        XCTAssertNil(info(.padel, rules: r, first: nil, ours: .you, ""))
    }

    func testTableTennisDoublesNamesGameOneOnly() {
        let r = RacketLiveRules(kind: .rally, pointsTo: 11)
        XCTAssertEqual(info(.tableTennis, rules: r, first: .us, ours: .you, "")?.player, .you)
        XCTAssertEqual(info(.tableTennis, rules: r, first: .us, ours: .you, "ut")?.side, .them, "two serves each")
        XCTAssertEqual(info(.tableTennis, rules: r, first: .us, ours: .you, "utut")?.player, .partner, "then your partner")
        XCTAssertEqual(info(.tableTennis, rules: r, first: .us, ours: .you, "utututut")?.player, .you)
        XCTAssertEqual(info(.tableTennis, rules: r, first: .them, ours: .partner, "ut")?.player, .partner,
                       "they serve first: your first server serves your first turn")
        XCTAssertNil(info(.tableTennis, rules: r, first: .us, ours: .you, unit: 1,
                          previous: [RacketUnitScore(scoreFor: 11, scoreAgainst: 5)], "ut")?.player,
                     "game 2's first server is the pair's free choice")
    }

    func testBadmintonDoublesTracksCourtsAndPlayers() {
        let r = RacketLiveRules(kind: .rally, pointsTo: 21, cap: 30)
        var i = info(.badminton, rules: r, first: .us, ours: .partner, "")
        XCTAssertEqual(i?.player, .partner)
        XCTAssertEqual(i?.court, .right, "0: right court")
        i = info(.badminton, rules: r, first: .us, ours: .partner, "u")
        XCTAssertEqual(i?.player, .partner, "the server keeps serving, now from the left")
        XCTAssertEqual(i?.court, .left)
        i = info(.badminton, rules: r, first: .us, ours: .partner, "ut")
        XCTAssertEqual(i?.side, .them)
        XCTAssertEqual(i?.court, .left, "their score 1: left court")
        XCTAssertNil(i?.player)
        i = info(.badminton, rules: r, first: .us, ours: .partner, "utu")
        XCTAssertEqual(i?.player, .you, "you won the serve back at 2: whoever is in the right court — you, since you swapped")
        XCTAssertEqual(i?.court, .right)
        // They serve first: your first server serves your first turn, from the court of your score.
        i = info(.badminton, rules: r, first: .them, ours: .you, "u")
        XCTAssertEqual(i?.player, .you)
        XCTAssertEqual(i?.court, .left)
        i = info(.badminton, rules: r, first: .them, ours: .you, "ut" + "u")
        XCTAssertEqual(i?.player, .partner, "back at 2, the right court is your partner's (no swap while receiving)")
    }

    func testPickleballDoublesNamesServerOneAndTwo() {
        let r = sideOut()
        var i = info(.pickleball, rules: r, first: nil, ours: .you, "")
        XCTAssertEqual(i?.player, .you)
        XCTAssertEqual(i?.serverNumber, 2, "the start: one server, called 2")
        i = info(.pickleball, rules: r, first: nil, ours: .you, "u")
        XCTAssertEqual(i?.player, .you)
        i = info(.pickleball, rules: r, first: nil, ours: .you, "ut")
        XCTAssertEqual(i?.side, .them)
        XCTAssertEqual(i?.serverNumber, 1)
        i = info(.pickleball, rules: r, first: nil, ours: .you, "ut" + "uu")
        XCTAssertEqual(i?.side, .us)
        XCTAssertEqual(i?.serverNumber, 1)
        XCTAssertEqual(i?.player, .partner, "score 1: you swapped sides, your partner is on the right")
        i = info(.pickleball, rules: r, first: nil, ours: .you, "ut" + "uu" + "t")
        XCTAssertEqual(i?.serverNumber, 2)
        XCTAssertEqual(i?.player, .you)
    }

    func testSquashDoublesAndUnknownOrdersNameTheSideOnly() {
        let r = RacketLiveRules(kind: .rally, pointsTo: 11)
        XCTAssertNil(info(.squash, rules: r, first: .us, ours: .you, "")?.player)
        XCTAssertEqual(info(.squash, rules: r, first: .us, ours: .you, "")?.side, .us)
        XCTAssertNil(info(.tennis, rules: RacketLiveRules(kind: .sets, pointsTo: 6), first: .us, ours: nil, "")?.player)
    }

    // MARK: - Copy

    func testServeLinesFollowTheDoublesBoards() {
        let sides = (us: "Us", them: "Them")
        let mia = RacketDoublesServe.Info(side: .us, player: .partner)
        XCTAssertEqual(RacketServeCopy.doublesLine(mia, partner: "Mia", sides: sides), "Mia serving")
        XCTAssertEqual(RacketServeCopy.doublesLine(.init(side: .us, player: .partner, court: .right), partner: "Mia", sides: sides),
                       "Mia serving, right court")
        XCTAssertEqual(RacketServeCopy.doublesLine(.init(side: .us, player: .partner, serverNumber: 2), partner: "Mia", sides: sides),
                       "Mia, server 2")
        XCTAssertEqual(RacketServeCopy.doublesLine(.init(side: .us, player: .you), partner: "Mia", sides: sides), "You’re serving")
        XCTAssertEqual(RacketServeCopy.doublesLine(.init(side: .them, court: .left), partner: "Mia", sides: sides),
                       "Them serving, left court")
        XCTAssertEqual(RacketServeCopy.doublesLine(.init(side: .us), partner: "Mia", sides: sides), "Us serving")
    }

    func testTagServingLineNamesThePlayer() {
        let rs = [RacketRally(startSec: 1, endSec: 2, winner: .them), RacketRally(startSec: 3, endSec: 4)]
        XCTAssertEqual(RacketTagScore.servingLine(sport: .badminton, firstServer: .us, unitIndex: 0, previous: [], rallyID: rs[0].id,
                                                  rallies: rs, sides: ("Us", "Them"), ourFirst: .partner, partner: "Mia"),
                       "Mia serving, right court")
        XCTAssertEqual(RacketTagScore.servingLine(sport: .tennis, firstServer: .us, unitIndex: 0, previous: [], rallyID: rs[0].id,
                                                  rallies: rs, sides: ("Us", "Them"), ourFirst: .partner, partner: "Mia"),
                       "Mia serving")
    }

    func testSideOutCaptionAndPanelCopy() {
        let t = RacketLiveScore(rules: sideOut(), points: pts("uut")).tally
        XCTAssertEqual(RacketServeCopy.sideOutCaption(t, unitTitle: "Game 1", them: "Them", doubles: true), "Them serving · server 1")
        let u = RacketLiveScore(rules: sideOut(), points: pts("utuut")).tally
        XCTAssertEqual(RacketServeCopy.sideOutCaption(u, unitTitle: "Game 1", them: "Them", doubles: true), "Serving · server 2")
        let single = RacketLiveScore(rules: sideOut(doubles: false), points: []).tally
        XCTAssertEqual(RacketServeCopy.sideOutCaption(single, unitTitle: "Game 1", them: "Alex", doubles: false), "Game 1 · you’re serving")
        let p1 = RacketServeCopy.sideOutPanel(.init(side: .us, serverNumber: 1, sideOut: false, callAfter: "4 – 2 – 2"),
                                              sides: ("Us", "Them"), doubles: true)
        XCTAssertEqual(p1.title, "Server 1 lost the rally")
        XCTAssertEqual(p1.line, "No point. Your partner serves next.")
        let p2 = RacketServeCopy.sideOutPanel(.init(side: .us, serverNumber: 2, sideOut: true, callAfter: "2 – 4 – 1"),
                                              sides: ("Us", "Them"), doubles: true)
        XCTAssertEqual(p2.title, "Server 2 lost the rally")
        XCTAssertEqual(p2.line, "Side-out. They serve next.")
        XCTAssertEqual(RacketServeCopy.sideOutFootnote, "At the start of a game, only one server serves before the first side-out.")
    }

    func testWatchNotesFollowTheBoards() {
        XCTAssertEqual(RacketWatchCopy.note(.pickleball, format: RacketFormat(sport: .pickleball, bestOf: 3, sideOut: true)),
                       "Winning while receiving doesn’t score")
        XCTAssertEqual(RacketWatchCopy.note(.pickleball, format: RacketFormat(sport: .pickleball, bestOf: 3)), "Every rally scores")
        XCTAssertEqual(RacketWatchCopy.note(.tennis, serving: "You’re serving"), "You’re serving · tap for the point winner")
        XCTAssertEqual(RacketWatchCopy.note(.tennis), "Tap for the point winner")
        XCTAssertEqual(RacketWatchCopy.note(.padel, serving: "You’re serving"), "Tap for the point winner", "PdWatch has no serve line")
        // The context words who serves from the match.
        let ex = match(.tennis, first: .them)
        var c = RacketWatchContext(ex)
        XCTAssertEqual(c.note(score: RacketLiveScore(rules: ex.racketLiveRules(unitIndex: 0))), "Alex serving · tap for the point winner")
        c.firstServer = nil
        XCTAssertEqual(c.note(score: RacketLiveScore(rules: ex.racketLiveRules(unitIndex: 0))), "Tap for the point winner")
        let d = match(.tennis, partner: "Mia", first: .us, ours: .partner)
        XCTAssertEqual(RacketWatchContext(d).note(score: RacketLiveScore(rules: d.racketLiveRules(unitIndex: 0))),
                       "Mia serving · tap for the point winner")
    }

    func testTheWatchMatchPublishesTheSideOutTallyAndNote() {
        let ex = match(.pickleball, partner: "Mia", sideOut: true)
        var w = RacketWatchMatch(exerciseID: ex.id, unitIndex: 0, rules: ex.racketLiveRules(unitIndex: 0), breakSec: 120,
                                 startedAt: Date(timeIntervalSince1970: 0))
        _ = w.apply(.pointThem, now: Date(timeIntervalSince1970: 5))
        let st = w.state(context: RacketWatchContext(ex))
        XCTAssertEqual(st.note, "Winning while receiving doesn’t score")
        guard case .scoring(let s) = st.surface else { return XCTFail("scoring") }
        XCTAssertEqual(s.score.display, "0–0–1", "side-out to them after your one server lost")
        XCTAssertEqual(s.score.header(unitNumber: s.unitNumber), "Game 1 · they serve")
    }

    // MARK: - Tag sheet lines

    func testTennisTagLineIsGamesAndPoint() {
        let r = RacketLiveRules(kind: .sets, pointsTo: 6)
        var l = RacketTagSportLine.sets(rules: r, points: pts("uuuu" + "tttt" + "uuuu" + "uuu" + "t"))
        XCTAssertEqual(l.games, "Games 2–1")
        XCTAssertEqual(l.point, "Point 40–15")
        l = RacketTagSportLine.sets(rules: r, points: [])
        XCTAssertEqual(l.games, "Games 0–0")
        XCTAssertEqual(l.point, "Point 0–0")
        let stb = RacketTagSportLine.sets(rules: RacketLiveRules(kind: .sets, pointsTo: 6, superTiebreak: true), points: pts("ut"))
        XCTAssertEqual(stb.games, "Match tiebreak")
        XCTAssertEqual(stb.point, "1–1")
    }

    func testPickleballTagLineIsTheCallAndWhoServesNext() {
        let r = sideOut()
        var l = RacketTagSportLine.pickleball(rules: r, pointsBefore: pts("uuuu"), winner: nil, ourFirst: .partner, unitIndex: 0,
                                              partner: "Mia", sides: ("Us", "Them"), doubles: false)
        XCTAssertEqual(l.call, "4–0–2")
        l = RacketTagSportLine.pickleball(rules: sideOut(doubles: false), pointsBefore: pts("uuuu"), winner: .us, ourFirst: nil,
                                          unitIndex: 0, partner: nil, sides: ("You", "Alex"), doubles: false)
        XCTAssertEqual(l.call, "5–0")
        XCTAssertEqual(l.serve, "You serving next")
        l = RacketTagSportLine.pickleball(rules: sideOut(), pointsBefore: pts("ut"), winner: nil, ourFirst: .partner, unitIndex: 0,
                                          partner: "Mia", sides: ("Us", "Them"), doubles: true)
        XCTAssertEqual(l.call, "0–1–1")
        XCTAssertEqual(l.serve, "Them, server 1")
        l = RacketTagSportLine.pickleball(rules: sideOut(), pointsBefore: pts("ut") + pts("uu"), winner: nil, ourFirst: .you,
                                          unitIndex: 0, partner: "Mia", sides: ("Us", "Them"), doubles: true)
        XCTAssertEqual(l.serve, "Mia, server 1")
    }

    // MARK: - TnServe · PdWall · SqLet

    func testServeOutcomesImplyTheWinnerOnlyWhenTheServerIsKnown() {
        XCTAssertEqual(RacketServeOutcome.allCases.map(\.label),
                       ["First serve in", "Second serve in", "Double fault", "Ace", "Let, replay"])
        XCTAssertEqual(RacketServeOutcome.implied(.ace, server: .us).winner, .us)
        XCTAssertEqual(RacketServeOutcome.implied(.ace, server: .us).ending, .winner)
        XCTAssertEqual(RacketServeOutcome.implied(.doubleFault, server: .us).winner, .them)
        XCTAssertEqual(RacketServeOutcome.implied(.doubleFault, server: .them).ending, .doubleFault)
        XCTAssertNil(RacketServeOutcome.implied(.ace, server: nil).winner)
        XCTAssertEqual(RacketServeOutcome.implied(.letReplay, server: .us).ending, .letReplay)
        XCTAssertNil(RacketServeOutcome.implied(.firstIn, server: .us).winner)
    }

    func testWallAndLetAnswersSetTheEndingChip() {
        XCTAssertEqual(RacketWallBounce.allCases.map(\.title),
                       ["Bounced, then wall", "Hit the wall before bouncing", "Went out of the court"])
        XCTAssertEqual(RacketWallBounce.allCases.map(\.subtitle),
                       ["Still in play if returned in time", "Point against the hitter", "Depends on local rules; tag who won"])
        XCTAssertEqual(RacketWallBounce.ending(.wallFirst, current: nil), .hitWallFirst)
        XCTAssertEqual(RacketWallBounce.ending(.outOfCourt, current: .net), .out)
        XCTAssertNil(RacketWallBounce.ending(.bouncedThenWall, current: .hitWallFirst))
        XCTAssertEqual(RacketWallBounce.ending(.bouncedThenWall, current: .winner), .winner)
        XCTAssertEqual(RacketLetCall.allCases.map(\.title), ["Let", "Stroke", "No let"])
        XCTAssertEqual(RacketLetCall.allCases.map(\.subtitle),
                       ["Replay the rally", "Point to the player who was blocked", "Point to the other player"])
        XCTAssertEqual(RacketLetCall.allCases.map(\.ending), [.letReplay, .stroke, .noLet])
        XCTAssertEqual(RacketLetCall(ending: .stroke), .stroke)
        XCTAssertNil(RacketLetCall(ending: .tin))
        XCTAssertEqual(RacketTagDetail.link(for: .tennis)?.linkTitle, "Serve details")
        XCTAssertEqual(RacketTagDetail.link(for: .padel)?.linkTitle, "Did it bounce first?")
        XCTAssertEqual(RacketTagDetail.link(for: .squash)?.linkTitle, "Let, stroke or no let")
        XCTAssertNil(RacketTagDetail.link(for: .badminton))
    }

    func testTaggingKeepsOrClearsTheServeAndWallAnswers() {
        var r = RacketRally(startSec: 0, endSec: 5)
        r.serveRaw = RacketServeOutcome.ace.rawValue
        let tagged = RacketRallyMarking.tag([r], id: r.id, winner: .us, ending: .winner, lastShotBy: nil, notRally: false)
        XCTAssertEqual(tagged[0].serve, .ace, "nil keeps what's there")
        let wall = RacketRallyMarking.tag([r], id: r.id, winner: .them, ending: .hitWallFirst, lastShotBy: nil, notRally: false,
                                          serve: .some(nil), wall: .some(.wallFirst))
        XCTAssertNil(wall[0].serve)
        XCTAssertEqual(wall[0].wall, .wallFirst)
        let notRally = RacketRallyMarking.tag(wall, id: r.id, winner: nil, ending: nil, lastShotBy: nil, notRally: true,
                                              serve: .some(.ace), wall: .some(.wallFirst))
        XCTAssertNil(notRally[0].wall, "not a rally drops its answers")
        XCTAssertNil(notRally[0].serve)
    }

    // MARK: - Low items

    func testRecapDrillHeadline() {
        var ex = match(.tableTennis)
        ex.racketModeRaw = RacketMode.drill.rawValue
        ex.drillMeasureRaw = RacketDrillMeasure.longestRally.rawValue
        var b1 = SetLog(); b1.longestRally = 14; b1.completedAt = Date()
        var b2 = SetLog(); b2.longestRally = 19; b2.completedAt = Date()
        ex.sets = [b1, b2]
        XCTAssertEqual(RacketStats.recapDrillHeadline(ex), "Longest 19")
    }
}
