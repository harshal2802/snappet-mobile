import XCTest
@testable import Snappet

/// Unit tests for the **pure** racket video split (prompt 246, issue #438 step 3): the proposal from the step-1 / 2
/// marks (the boards' 1:14:10 match), range editing that keeps parts tiling the recording, the part ↔ game assignment
/// with "Score unconfirmed" for games with no score, recording-time → Photos-part mapping, the original-missing state,
/// the delete-original and keep-rallies numbers, and the Your videos rows. No device.
final class RacketVideoSplitTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let tt = RacketFormat(sport: .tableTennis, bestOf: 3, pointsTo: nil, superTiebreak: false)

    private func log(marks: [(RacketRecordingLog.MarkKind, Double)], end: Double) -> RacketRecordingLog {
        var l = RacketRecordingLog(startedAt: t0)
        l.runs = [.init(startSec: 0, endSec: end, endReasonRaw: nil)]
        l.marks = marks.map { .init(kindRaw: $0.0.rawValue, index: nil, startSec: $0.1, endSec: nil) }
        l.endedAt = t0.addingTimeInterval(end)
        return l
    }

    private func kinds(_ ps: [RacketVideoPart]) -> [RacketPartKind] { ps.map(\.kind) }
    private func ranges(_ ps: [RacketVideoPart]) -> [[Double]] { ps.map { [$0.startSec, $0.endSec] } }

    // MARK: Proposal

    func testProposalMatchesTheBoardsMatch() {
        let l = RacketVideoSeed.matchLog(startedAt: t0)
        let ps = RacketSplitProposal.propose(log: l, format: tt)
        XCTAssertEqual(kinds(ps), [.warmup, .game, .breakTime, .game, .breakTime, .game, .unsure, .notPlay])
        XCTAssertEqual(ranges(ps), [[0, 370], [370, 1480], [1480, 1560], [1560, 2720], [2720, 2820], [2820, 3990],
                                    [3990, 4320], [4320, 4450]])
        XCTAssertTrue(RacketSplitEditor.validate(ps, duration: 4450).isEmpty)
        XCTAssertEqual(RacketSplitProposal.promptLine(ps, unit: .game),
                       "Looks like 3 games and one more stretch of play, with breaks in between.")
    }

    func testNoMarksIsOneGame() {
        let ps = RacketSplitProposal.propose(log: log(marks: [], end: 600), format: tt)
        XCTAssertEqual(kinds(ps), [.game])
        XCTAssertEqual(ranges(ps), [[0, 600]])
    }

    func testPhoneNewGameMarksMakeGamesFromTheStart() {
        // Step 1's count: New game marks + 1 games, the first starting with the recording.
        let ps = RacketSplitProposal.propose(log: log(marks: [(.newGame, 600), (.newGame, 1200)], end: 1800), format: tt)
        XCTAssertEqual(kinds(ps), [.game, .game, .game])
    }

    func testWatchGameEndThenPhoneNewGameIsABreakNotAGame() {
        let ps = RacketSplitProposal.propose(log: log(marks: [(.newGame, 600), (.newGame, 660)], end: 1200), format: tt)
        XCTAssertEqual(kinds(ps), [.game, .breakTime, .game])
    }

    func testBreakToTheEndIsNotPlayAndShortStretchesFold() {
        let ps = RacketSplitProposal.propose(log: log(marks: [(.breakStart, 500), (.newGame, 502)], end: 900), format: tt)
        // The 2-second break folds into the game before it.
        XCTAssertEqual(kinds(ps), [.game, .game])
        let p2 = RacketSplitProposal.propose(log: log(marks: [(.breakStart, 800)], end: 900), format: tt)
        XCTAssertEqual(kinds(p2), [.game, .notPlay])
    }

    func testGamesBeyondTheFormatAreUnsure() {
        var l = log(marks: [(.newGame, 300), (.newGame, 600)], end: 900)
        l.baseSetIndex = 2      // two games already logged before this recording, best of 3
        XCTAssertEqual(kinds(RacketSplitProposal.propose(log: l, format: tt)), [.game, .unsure, .unsure])
    }

    func testDrillPartsComeFromTheTimers() {
        var l = RacketRecordingLog(startedAt: t0)
        l.runs = [.init(startSec: 0, endSec: 400, endReasonRaw: nil)]
        l.marks = [.init(kindRaw: "block", index: 0, startSec: 10, endSec: 110),
                   .init(kindRaw: "rest", index: 0, startSec: 110, endSec: 170),
                   .init(kindRaw: "block", index: 1, startSec: 175, endSec: 275)]
        l.baseSetIndex = 1
        let ps = RacketSplitProposal.drillParts(log: l)
        XCTAssertEqual(kinds(ps), [.warmup, .drillBlock, .rest, .drillBlock, .notPlay])
        XCTAssertEqual(ps.filter { $0.kind == .drillBlock }.map(\.setIndex), [1, 2])
        XCTAssertTrue(RacketSplitEditor.validate(ps, duration: 400).isEmpty)
    }

    // MARK: Editing

    private func three() -> [RacketVideoPart] {
        [RacketVideoPart(kind: .warmup, startSec: 0, endSec: 100),
         RacketVideoPart(kind: .game, startSec: 100, endSec: 500),
         RacketVideoPart(kind: .breakTime, startSec: 500, endSec: 600)]
    }

    func testSetBoundsMovesNeighboursAndClamps() {
        let ps = three()
        let moved = RacketSplitEditor.setBounds(ps, id: ps[1].id, start: 80, end: 550, duration: 600)
        XCTAssertEqual(ranges(moved), [[0, 80], [80, 550], [550, 600]])
        // Can't swallow a neighbour: each keeps the minimum length; can't leave the recording.
        let clamped = RacketSplitEditor.setBounds(ps, id: ps[1].id, start: -50, end: 9999, duration: 600)
        XCTAssertEqual(ranges(clamped), [[0, 5], [5, 595], [595, 600]])
        XCTAssertTrue(RacketSplitEditor.validate(clamped, duration: 600).isEmpty)
        // The first part always starts at 0, the last ends at the recording's end.
        let first = RacketSplitEditor.setBounds(ps, id: ps[0].id, start: 40, end: 120, duration: 600)
        XCTAssertEqual(ranges(first), [[0, 120], [120, 500], [500, 600]])
    }

    func testSplitMergeAndKind() {
        let ps = three()
        let split = RacketSplitEditor.split(ps, id: ps[1].id, at: 300)
        XCTAssertEqual(ranges(split), [[0, 100], [100, 300], [300, 500], [500, 600]])
        XCTAssertEqual(RacketSplitEditor.split(ps, id: ps[1].id, at: 102).count, 3, "too close to an edge")
        let merged = RacketSplitEditor.mergeWithNext(split, id: split[1].id)
        XCTAssertEqual(ranges(merged), [[0, 100], [100, 500], [500, 600]])
        let extra = RacketSplitEditor.setBelongs([RacketVideoPart(kind: .unsure, startSec: 0, endSec: 10)],
                                                 id: ps[0].id, belongs: .thisMatch)
        XCTAssertEqual(extra[0].kind, .unsure, "only the part with that id changes")
        var u = [RacketVideoPart(kind: .unsure, startSec: 0, endSec: 10)]
        u = RacketSplitEditor.setBelongs(u, id: u[0].id, belongs: .thisMatch)
        XCTAssertEqual(u[0].kind, .game)
        XCTAssertTrue(u[0].isExtra)
        u = RacketSplitEditor.setBelongs(u, id: u[0].id, belongs: .practice)
        XCTAssertEqual(u[0].kind, .unsure)
        XCTAssertEqual(RacketSplitReview.status(u[0]), .notCounted)
    }

    func testValidateFindsOverlapsGapsAndRange() {
        let bad = [RacketVideoPart(kind: .game, startSec: 0, endSec: 100),
                   RacketVideoPart(kind: .game, startSec: 90, endSec: 200),
                   RacketVideoPart(kind: .game, startSec: 210, endSec: 700)]
        let issues = RacketSplitEditor.validate(bad, duration: 600)
        XCTAssertTrue(issues.contains(.overlap(index: 1)))
        XCTAssertTrue(issues.contains(.gap(index: 2)))
        XCTAssertTrue(issues.contains(.outOfRange(index: 2)))
        let fixed = RacketSplitEditor.normalized(bad, duration: 600)
        XCTAssertTrue(RacketSplitEditor.validate(fixed, duration: 600).isEmpty)
        XCTAssertEqual(RacketSplitEditor.validate([], duration: 10), [.empty])
    }

    // MARK: Assignment

    func testAssignMatchesWatchGamesByTimeAndAddsUnconfirmedOnes() {
        let l = RacketVideoSeed.matchLog(startedAt: t0)
        var parts = RacketSplitProposal.propose(log: l, format: tt)
        // The player says the unsure stretch is an extra game of this match.
        let unsure = parts.first { $0.kind == .unsure }!
        parts = RacketSplitEditor.setBelongs(parts, id: unsure.id, belongs: .thisMatch)
        var g1 = SetLog(completedAt: t0.addingTimeInterval(1482)); g1.scoreFor = 11; g1.scoreAgainst = 9; g1.scoreFromWatch = true
        var g2 = SetLog(completedAt: t0.addingTimeInterval(2722)); g2.scoreFor = 9; g2.scoreAgainst = 11; g2.scoreFromWatch = true
        let out = RacketSplitAssign.apply(parts: parts, sets: [g1, g2], base: 0, startedAt: t0)
        XCTAssertEqual(out.added, 2, "game 3 and the extra game get 'Score unconfirmed' games")
        XCTAssertEqual(out.sets.count, 4)
        XCTAssertEqual(out.sets.map { $0.racketScoreState?.label }, ["11–9 from Watch", "9–11 from Watch",
                                                                       "Score unconfirmed", "Score unconfirmed"])
        let games = out.parts.filter { $0.kind == .game }
        XCTAssertEqual(games.map(\.setIndex), [0, 1, 2, 3])
        XCTAssertEqual(RacketSplitAssign.title(games[0], ordinal: 1, sets: out.sets, unit: .game), "Game 1 · 11–9")
        XCTAssertEqual(RacketSplitAssign.title(games[2], ordinal: 3, sets: out.sets, unit: .game), "Game 3 · no score")
        XCTAssertEqual(RacketSplitAssign.title(games[3], ordinal: 4, sets: out.sets, unit: .game), "Extra game")
        XCTAssertEqual(RacketSplitAssign.missingScore(parts: out.parts, sets: out.sets, unit: .game)?.line,
                       "Game 3 has video but no score")
        // Unconfirmed games count for neither side (review5 M5).
        XCTAssertEqual(out.sets.compactMap(\.racketScore).count, 2)
        // Applying again is idempotent: the new games are matched by their time now.
        let again = RacketSplitAssign.apply(parts: out.parts, sets: out.sets, base: 0, startedAt: t0)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.sets, out.sets)
    }

    func testAssignKeepsEarlierGamesAndOrder() {
        // Two games logged before the recording; a phone-scored game (no time inside) fills the first part.
        var before = SetLog(); before.scoreFor = 11; before.scoreAgainst = 3
        var phone = SetLog(); phone.scoreFor = 11; phone.scoreAgainst = 7
        let parts = [RacketVideoPart(kind: .game, startSec: 0, endSec: 300),
                     RacketVideoPart(kind: .breakTime, startSec: 300, endSec: 400),
                     RacketVideoPart(kind: .game, startSec: 400, endSec: 700)]
        let out = RacketSplitAssign.apply(parts: parts, sets: [before, before, phone], base: 2, startedAt: t0)
        XCTAssertEqual(out.sets.count, 4)
        XCTAssertEqual(out.sets[2].scoreAgainst, 7)
        XCTAssertEqual(out.sets[3].scoreUnconfirmed, true)
        XCTAssertEqual(out.parts.map(\.setIndex), [2, nil, 3])
        XCTAssertEqual(out.sets[3].durationSec, 300)
    }

    func testScoreEditConfirms() {
        var s = SetLog(); s.scoreUnconfirmed = true
        var entered = SetLog(); entered.scoreFor = 11; entered.scoreAgainst = 8
        RacketScoreEdit.apply(entered, to: &s)
        XCTAssertEqual(s.racketScoreState, .confirmed(RacketUnitScore(scoreFor: 11, scoreAgainst: 8)))
        var w = SetLog(); w.scoreFor = 9; w.scoreAgainst = 11; w.scoreFromWatch = true
        RacketScoreEdit.apply(entered, to: &w)
        XCTAssertNil(w.scoreFromWatch)
    }

    func testReviewLines() {
        let l = RacketVideoSeed.matchLog(startedAt: t0)
        let ps = RacketSplitProposal.propose(log: l, format: tt)
        var g1 = SetLog(completedAt: t0.addingTimeInterval(1482)); g1.scoreFor = 11; g1.scoreAgainst = 9; g1.scoreFromWatch = true
        let out = RacketSplitAssign.apply(parts: ps, sets: [g1], base: 0, startedAt: t0)
        let sets = [g1]   // before Apply: only the logged game
        let lines = out.parts.enumerated().map { k, p in
            RacketSplitReview.detail(p, sets: sets, unit: .game, isLast: k == out.parts.count - 1)
        }
        XCTAssertEqual(lines[0], "0:00–6:10 · not counted")
        XCTAssertEqual(lines[1], "6:10–24:40 · 11–9 from Watch")
        XCTAssertEqual(lines[3], "26:00–45:20 · no score logged")
        XCTAssertEqual(lines[6], "1:06:30–1:12:00 · an extra game or practice?")
        XCTAssertEqual(lines[7], "1:12:00–1:14:10 · packing up, not counted")
        XCTAssertEqual(out.parts.map { RacketSplitReview.status($0) }.map(\.rawValue),
                       ["Not counted", "Matched", "Not counted", "Matched", "Not counted", "Matched", "Unsure", "Not counted"])
    }

    // MARK: Photos parts

    func testSegmentsSpanTenMinutePartsAndGaps() {
        var l = RacketRecordingLog(startedAt: t0)
        l.runs = [.init(startSec: 0, endSec: 900, endReasonRaw: "call"), .init(startSec: 960, endSec: 1300, endReasonRaw: nil)]
        l.assets = [.init(localIdentifier: "a", startSec: 0, durationSec: 600),
                    .init(localIdentifier: "b", startSec: 600, durationSec: nil),   // runs to the interruption
                    .init(localIdentifier: "c", startSec: 960, durationSec: 340)]
        let segs = RacketVideoMap.segments(start: 550, end: 1000, log: l)
        XCTAssertEqual(segs, [
            RacketVideoSegment(localIdentifier: "a", assetStart: 550, assetEnd: 600, timelineStart: 550),
            RacketVideoSegment(localIdentifier: "b", assetStart: 0, assetEnd: 300, timelineStart: 600),
            RacketVideoSegment(localIdentifier: "c", assetStart: 0, assetEnd: 40, timelineStart: 960),
        ])
        XCTAssertTrue(RacketVideoMap.segments(start: 910, end: 950, log: l).isEmpty, "the interruption has no video")
        // Once the original is deleted, the derived videos play.
        l.derived = [.init(localIdentifier: "p1", startSec: 500, endSec: 800)]
        l.originalDeleted = true
        XCTAssertEqual(RacketVideoMap.segments(start: 550, end: 1000, log: l),
                       [RacketVideoSegment(localIdentifier: "p1", assetStart: 50, assetEnd: 300, timelineStart: 550)])
    }

    func testOriginalMissingState() {
        XCTAssertEqual(RacketOriginalCheck.state(needed: [], found: []), .noVideo)
        XCTAssertEqual(RacketOriginalCheck.state(needed: ["a", "b"], found: ["a", "b"]), .available)
        XCTAssertEqual(RacketOriginalCheck.state(needed: ["a", "b"], found: ["a"]), .missing(count: 1))
    }

    // MARK: Space

    func testDeletePlanKeepsCountedPartsOnly() {
        var l = RacketVideoSeed.matchLog(startedAt: t0)
        var parts = RacketSplitProposal.propose(log: l, format: tt)
        parts = RacketSplitEditor.setBelongs(parts, id: parts.first { $0.kind == .unsure }!.id, belongs: .thisMatch)
        l.split = RacketSplit(parts: parts, appliedAt: t0)
        l.assets = [.init(localIdentifier: "a", startSec: 0, durationSec: 4450)]
        let plan = RacketVideoSpace.deletePlan(log: l)
        XCTAssertEqual(plan.parts.count, 4)
        XCTAssertEqual(plan.keepSec, 1110 + 1160 + 1170 + 330)
        XCTAssertEqual(RacketVideoSpace.partsLine(plan), "4 · 1 h 3 min")
        XCTAssertTrue(plan.canDelete)
        XCTAssertFalse(plan.fits(freeBytes: 1_000_000))
        XCTAssertEqual(RacketVideoSpace.size(plan.neededBytes), "about 3.8 GB")
    }

    func testKeepRalliesMergesAndCountsDrills() {
        let rallies = [RacketRally(startSec: 10, endSec: 15), RacketRally(startSec: 16.5, endSec: 20),
                       RacketRally(startSec: 40, endSec: 45), RacketRally(startSec: 50, endSec: 52, notRally: true)]
        let r = RacketKeepRallies.ranges(rallies, duration: 44)
        XCTAssertEqual(r, [9...21, 39...44])

        func ex(drill: Bool, rallies: [RacketRally]) -> SessionExercise {
            var e = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
            e.disciplineRaw = WorkoutDiscipline.racket.rawValue
            e.racketModeRaw = (drill ? RacketMode.drill : .match).rawValue
            var l = RacketRecordingLog(startedAt: t0)
            l.runs = [.init(startSec: 0, endSec: 600, endReasonRaw: nil)]
            l.assets = [.init(localIdentifier: drill ? "d" : "m", startSec: 0, durationSec: 600)]
            l.rallies = rallies
            e.racketRecordingLog = l
            return e
        }
        let plan = RacketKeepRallies.plan([ex(drill: false, rallies: rallies), ex(drill: true, rallies: [RacketRally(startSec: 100, endSec: 110)])])
        XCTAssertEqual(plan.rallies, 4)
        XCTAssertEqual(plan.matchRallies, 3)
        XCTAssertEqual(plan.drillRallies, 1, "the drill's rallies count too (review5)")
        XCTAssertEqual(plan.fullVideos, 2)
        XCTAssertEqual(RacketKeepRallies.sourceLine(plan), "3 from matches, 1 from drills")
        XCTAssertTrue(plan.canKeep)
        XCTAssertGreaterThan(plan.freedBytes, 0)
    }

    // MARK: Your videos

    func testVideoRowsBeforeAndAfterSplit() {
        var e = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
        e.disciplineRaw = WorkoutDiscipline.racket.rawValue
        e.racketSportRaw = RacketSport.tableTennis.rawValue
        e.racketBestOf = 3
        var l = RacketVideoSeed.matchLog(startedAt: t0)
        e.racketRecordingLog = l
        XCTAssertEqual(RacketVideoRows.rows(for: e).map(\.title), ["Whole recording"])
        XCTAssertEqual(RacketVideoRows.rows(for: e).first?.line, "1:14:10 · not split yet")

        let out = RacketSplitAssign.apply(parts: RacketSplitProposal.propose(log: l, format: tt), sets: [], base: 0, startedAt: t0)
        l.split = RacketSplit(parts: out.parts, appliedAt: t0)
        l.rallies = [RacketRally(startSec: 400, endSec: 409, winner: .us)]
        e.sets = out.sets
        e.racketRecordingLog = l
        let rows = RacketVideoRows.rows(for: e)
        XCTAssertEqual(rows.map(\.title), ["Game 1", "Game 2", "Game 3"])
        XCTAssertEqual(rows[0].scoreChip, "Unconfirmed")
        XCTAssertEqual(rows[0].tagLine, "1 marked by you")
        XCTAssertEqual(rows[1].tagLine, "Not marked yet")
        XCTAssertEqual(RacketVideoRows.recapLine(e), "3 videos · 1 rally tagged")
    }

    func testRallyFindingReadsTheCapabilityRegistry() {
        // Step 5 (prompt 248): every sport has the placeholder model; the no-model preview takes the by-hand path.
        for s in RacketSport.allCases {
            XCTAssertEqual(RacketRallyFinding.availability(for: s), .available(modelName: "Snappet placeholder v1"))
            XCTAssertEqual(RacketRallyFinding.availability(for: s, noModel: true), .notYet)
        }
        XCTAssertEqual(RacketRallyFinding.notYetLine(.tableTennis), "Rally finding isn’t available for table tennis yet.")
    }

    func testTimes() {
        XCTAssertEqual(RacketVideoTime.clock(3990), "1:06:30")
        XCTAssertEqual(RacketVideoTime.clock(370), "6:10")
        XCTAssertEqual(RacketVideoTime.length(3770), "1 h 3 min")
        XCTAssertEqual(RacketVideoTime.length(45), "45 s")
        XCTAssertEqual(RacketVideoTime.length(3600), "1 h")
        XCTAssertEqual(RacketVideoTime.precise(161.45), "2:41.4")
    }
}
