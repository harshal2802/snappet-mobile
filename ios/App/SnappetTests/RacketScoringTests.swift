import XCTest
@testable import Snappet

/// Unit tests for the **pure** racket rules engine (prompt 203): per-sport game / set validity, the match
/// state derived from logged units, pressure, formats, labels and rounds. No device.
final class RacketScoringTests: XCTestCase {

    private func u(_ a: Int, _ b: Int, tb: (Int, Int)? = nil, stb: Bool = false) -> RacketUnitScore {
        RacketUnitScore(scoreFor: a, scoreAgainst: b, tiebreakFor: tb?.0, tiebreakAgainst: tb?.1, superTiebreak: stb)
    }

    private let tt = RacketFormat.defaults(for: .tableTennis)
    private let badminton = RacketFormat.defaults(for: .badminton)
    private let tennis = RacketFormat.defaults(for: .tennis)

    // MARK: - Points games

    func testTableTennisGameRules() {
        XCTAssertEqual(RacketScoring.check(u(11, 7), format: tt), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(9, 11), format: tt), .valid(won: false))
        XCTAssertEqual(RacketScoring.check(u(12, 10), format: tt), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(15, 13), format: tt), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(11, 0), format: tt), .valid(won: true))
        // Not finished / not win-by-2 → saveable warnings, never valid.
        XCTAssertFalse(RacketScoring.check(u(11, 10), format: tt).isValid)
        XCTAssertFalse(RacketScoring.check(u(10, 8), format: tt).isValid)
        XCTAssertFalse(RacketScoring.check(u(13, 10), format: tt).isValid)
        XCTAssertFalse(RacketScoring.check(u(11, 11), format: tt).isValid)
    }

    func testBadmintonCapAtThirty() {
        XCTAssertEqual(RacketScoring.check(u(21, 15), format: badminton), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(22, 20), format: badminton), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(30, 29), format: badminton), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(28, 30), format: badminton), .valid(won: false))
        XCTAssertFalse(RacketScoring.check(u(31, 29), format: badminton).isValid)
        XCTAssertFalse(RacketScoring.check(u(30, 25), format: badminton).isValid)
    }

    func testPickleballGamesToFifteen() {
        let f = RacketFormat(sport: .pickleball, bestOf: 3, pointsTo: 15)
        XCTAssertEqual(RacketScoring.check(u(15, 12), format: f), .valid(won: true))
        XCTAssertFalse(RacketScoring.check(u(11, 5), format: f).isValid)
    }

    // MARK: - Tennis sets

    func testTennisSetRules() {
        XCTAssertEqual(RacketScoring.check(u(6, 4), format: tennis), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(7, 5), format: tennis), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(3, 6), format: tennis), .valid(won: false))
        XCTAssertFalse(RacketScoring.check(u(6, 5), format: tennis).isValid)
        XCTAssertFalse(RacketScoring.check(u(8, 6), format: tennis).isValid)
        // 7–6 needs a tiebreak that agrees with the set.
        XCTAssertFalse(RacketScoring.check(u(7, 6), format: tennis).isValid)
        XCTAssertEqual(RacketScoring.check(u(7, 6, tb: (7, 5)), format: tennis), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(6, 7, tb: (5, 7)), format: tennis), .valid(won: false))
        XCTAssertFalse(RacketScoring.check(u(7, 6, tb: (5, 7)), format: tennis).isValid)
        XCTAssertFalse(RacketScoring.check(u(7, 6, tb: (7, 6)), format: tennis).isValid)
        XCTAssertTrue(RacketScoring.needsTiebreak(6, 7, gamesTo: 6))
        XCTAssertFalse(RacketScoring.needsTiebreak(7, 5, gamesTo: 6))
    }

    func testSuperTiebreakToTen() {
        let f = RacketFormat(sport: .tennis, bestOf: 3, superTiebreak: true)
        XCTAssertTrue(f.isSuperTiebreak(index: 2))
        XCTAssertFalse(f.isSuperTiebreak(index: 1))
        XCTAssertEqual(RacketScoring.check(u(10, 8, stb: true), format: f), .valid(won: true))
        XCTAssertEqual(RacketScoring.check(u(12, 14, stb: true), format: f), .valid(won: false))
        XCTAssertFalse(RacketScoring.check(u(10, 9, stb: true), format: f).isValid)
        // Only set-based sports take a super tiebreak.
        XCTAssertFalse(RacketFormat(sport: .tableTennis, bestOf: 5, superTiebreak: true).superTiebreak)
    }

    // MARK: - Match state

    func testBestOfFiveDecidedAtThree() {
        let units = [u(11, 7), u(9, 11), u(12, 10), u(11, 8)]
        let s = RacketScoring.state(units: units, format: tt)
        XCTAssertEqual(s.won, 3); XCTAssertEqual(s.lost, 1)
        XCTAssertEqual(s.result, true)
        XCTAssertEqual(s.shortResult, "W 3–1")
        XCTAssertEqual(RacketScoring.totals(units).forTotal, 43)
        XCTAssertEqual(RacketScoring.totals(units).against, 36)
    }

    func testInPlayAndPressure() {
        let s = RacketScoring.state(units: [u(11, 7), u(9, 11), u(12, 10)], format: tt)
        XCTAssertNil(s.result)
        XCTAssertEqual(s.shortResult, "2–1")
        XCTAssertEqual(RacketScoring.pressure(s, format: tt), .matchPointFor)
        let level = RacketScoring.state(units: [u(11, 7), u(7, 11), u(11, 9), u(9, 11)], format: tt)
        XCTAssertEqual(RacketScoring.pressure(level, format: tt), .decider)
    }

    func testLevelUnitsCountForNobodyAndOpenPlayNeverDecides() {
        let open = RacketFormat(sport: .tableTennis, bestOf: nil)
        let s = RacketScoring.state(units: [u(11, 3), u(11, 4), u(11, 5), u(11, 11)], format: open)
        XCTAssertEqual(s.won, 3); XCTAssertEqual(s.lost, 0)
        XCTAssertNil(s.result)
        XCTAssertEqual(open.label, "Open play")
        XCTAssertEqual(RacketScoring.pressure(s, format: open), .none)
    }

    func testRetirementDecidesWithoutScores() {
        let s = RacketScoring.state(units: [u(6, 2)], format: tennis, end: .opponentRetired)
        XCTAssertEqual(s.result, true)
        XCTAssertEqual(s.shortResult, "W 1–0 ret.")
        XCTAssertEqual(RacketScoring.state(units: [], format: tennis, end: .walkoverLoss).shortResult, "L w/o")
    }

    func testBestOfOneAndUnitsToWin() {
        XCTAssertEqual(RacketFormat(sport: .badminton, bestOf: 1).unitsToWin, 1)
        XCTAssertEqual(RacketFormat(sport: .tableTennis, bestOf: 7).unitsToWin, 4)
        XCTAssertEqual(RacketScoring.state(units: [u(21, 19)], format: RacketFormat(sport: .badminton, bestOf: 1)).result, true)
    }

    // MARK: - Labels & entry

    func testScoreLabels() {
        XCTAssertEqual(u(11, 7).label, "11–7")
        XCTAssertEqual(u(6, 7, tb: (5, 7)).label, "6–7 (5)")
        XCTAssertEqual(u(6, 7, tb: (5, 7)).longLabel, "6–7 (5–7)")
        XCTAssertEqual(u(7, 6, tb: (9, 7)).label, "7–6 (7)")
    }

    func testInitialScoreAndVerdict() {
        XCTAssertTrue(RacketScoring.initialScore(format: tt, superTiebreak: false) == (11, 0))
        XCTAssertTrue(RacketScoring.initialScore(format: tennis, superTiebreak: false) == (6, 0))
        XCTAssertTrue(RacketScoring.initialScore(format: tennis, superTiebreak: true) == (10, 0))
        let after = RacketScoring.state(units: [u(11, 7), u(9, 11), u(12, 10), u(11, 8)], format: tt)
        XCTAssertEqual(RacketScoring.verdictLine(.valid(won: true), unitNumber: 4, unit: .game, after: after),
                       "You win game 4 · match won 3–1")
    }

    func testFormatDefaultsPerSport() {
        XCTAssertEqual(tt.label, "Best of 5")
        XCTAssertEqual(tennis.label, "Best of 3 sets")
        XCTAssertEqual(RacketSport.badminton.defaultPointsTo, 21)
        XCTAssertTrue(RacketSport.padel.defaultsToDoubles)
        XCTAssertEqual(RacketSport.squash.unit, .game)
        XCTAssertEqual(RacketSport.padel.unit, .set)
    }

    func testAccuracy() {
        XCTAssertEqual(RacketScoring.accuracy(made: 38, tried: 50)!, 0.76, accuracy: 0.0001)
        XCTAssertNil(RacketScoring.accuracy(made: 3, tried: 0))
        XCTAssertEqual(RacketScoring.accuracy(made: 60, tried: 50), 1)   // clamped
    }

    func testRoundsLadder() {
        XCTAssertEqual(RacketRounds.next(after: "R32"), "R16")
        XCTAssertEqual(RacketRounds.next(after: "qf"), "SF")
        XCTAssertNil(RacketRounds.next(after: "F"))
        XCTAssertEqual(RacketRounds.next(after: "Group 1"), "Group 2")
        XCTAssertNil(RacketRounds.next(after: ""))
        XCTAssertNil(RacketRounds.next(after: "Final"))
    }
}
