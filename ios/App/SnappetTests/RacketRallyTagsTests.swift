import XCTest
@testable import Snappet

/// Unit tests for the **pure** rally marks and tags (prompt 246, issue #438 step 3): Mark start / Mark end, FixRally
/// edits, tagging (winner, per-sport endings, doubles last shot, Not a rally), "From your tags" numbers, TagDone,
/// rallies-only playback, the analysed overlay, and tags counting in history. No device.
final class RacketRallyTagsTests: XCTestCase {

    func testMarkingClampsSwapsAndRejects() {
        guard case .success(let r) = RacketRallyMarking.rally(start: 12, end: 8, within: 10, 100, existing: []) else {
            return XCTFail("either edge can be marked first")
        }
        XCTAssertEqual([r.startSec, r.endSec], [10, 12])
        XCTAssertEqual(RacketRallyMarking.rally(start: nil, end: 20, within: 0, 100, existing: []), .failure(.noStart))
        XCTAssertEqual(RacketRallyMarking.rally(start: 20, end: 20.2, within: 0, 100, existing: []), .failure(.tooShort))
        let existing = [RacketRally(startSec: 30, endSec: 40)]
        XCTAssertEqual(RacketRallyMarking.rally(start: 35, end: 45, within: 0, 100, existing: existing), .failure(.overlaps))
        guard case .success = RacketRallyMarking.rally(start: 40, end: 45, within: 0, 100, existing: existing) else {
            return XCTFail("touching is fine")
        }
        // The end is clamped to the part.
        guard case .success(let c) = RacketRallyMarking.rally(start: 95, end: 130, within: 0, 100, existing: []) else {
            return XCTFail()
        }
        XCTAssertEqual(c.endSec, 100)
    }

    func testFixSplitMerge() {
        let a = RacketRally(startSec: 10, endSec: 20), b = RacketRally(startSec: 25, endSec: 30)
        XCTAssertNil(RacketRallyMarking.fix([a, b], id: a.id, start: 10, end: 26, within: 0, 100), "can't overlap the next")
        let fixed = RacketRallyMarking.fix([a, b], id: a.id, start: 9, end: 22, within: 0, 100)
        XCTAssertEqual(fixed?.first?.endSec, 22)
        let split = RacketRallyMarking.splitInTwo([a, b], id: a.id)
        XCTAssertEqual(split.map(\.startSec), [10, 15, 25])
        let merged = RacketRallyMarking.mergeWithNext(split, id: split[1].id)
        XCTAssertEqual(merged.map { [$0.startSec, $0.endSec] }, [[10, 15], [15, 30]])
    }

    func testTaggingAndNextUntagged() {
        let rs = [RacketRally(startSec: 1, endSec: 5), RacketRally(startSec: 6, endSec: 9), RacketRally(startSec: 10, endSec: 12)]
        var t = RacketRallyMarking.tag(rs, id: rs[0].id, winner: .us, ending: .out, lastShotBy: "Mia", notRally: false)
        XCTAssertTrue(t[0].isTagged)
        XCTAssertEqual(t[0].lastShotBy, "Mia")
        XCTAssertEqual(RacketRallyMarking.nextUntagged(t, after: rs[0].id)?.id, rs[1].id)
        t = RacketRallyMarking.tag(t, id: rs[1].id, winner: nil, ending: nil, lastShotBy: nil, notRally: true)
        XCTAssertFalse(t[1].isRally)
        XCTAssertEqual(RacketRallyMarking.nextUntagged(t, after: rs[0].id)?.id, rs[2].id, "Not a rally is skipped")
        // A let is replayed: tagged with no winner.
        t = RacketRallyMarking.tag(t, id: rs[2].id, winner: nil, ending: .letReplay, lastShotBy: nil, notRally: false)
        XCTAssertTrue(t[2].isTagged)
        XCTAssertNil(RacketRallyMarking.nextUntagged(t, after: rs[2].id))
    }

    func testEndingsPerSportFollowTheBoards() {
        XCTAssertEqual(RacketRallyEnding.choices(for: .tableTennis).map(\.label),
                       ["Out", "Net", "Double bounce", "Serve fault", "Let (replay)", "Edge ball", "Missed swing", "Interrupted"])
        XCTAssertEqual(RacketRallyEnding.choices(for: .badminton).first?.label, "Landed in")
        XCTAssertTrue(RacketRallyEnding.choices(for: .pickleball).contains(.kitchenFault))
        XCTAssertTrue(RacketRallyEnding.choices(for: .padel).contains(.hitWallFirst))
        XCTAssertEqual(RacketRallyEnding.choices(for: .squash).map(\.label),
                       ["Winner", "Tin", "Out", "Not up", "Service fault", "Let (replay)", "Stroke", "No let"])
        for s in RacketSport.allCases { XCTAssertEqual(RacketRallyEnding.choices(for: s).count, 8) }
    }

    func testSummaryMatchesTheManualSummaryBoard() {
        // TtManualSummary: 5 marked, 3 tagged, longest 9.4 s, You 2 / Alex 1, Out 2, Net 1.
        let rs = [RacketRally(startSec: 0, endSec: 9.4, winner: .us, ending: .out),
                  RacketRally(startSec: 20, endSec: 26, winner: .them, ending: .net),
                  RacketRally(startSec: 30, endSec: 35, winner: .us, ending: .out),
                  RacketRally(startSec: 40, endSec: 44),
                  RacketRally(startSec: 50, endSec: 52),
                  RacketRally(startSec: 60, endSec: 70, notRally: true)]
        let s = RacketTagSummary.make(rs, sport: .tableTennis)
        XCTAssertEqual(s.marked, 5)
        XCTAssertEqual(s.tagged, 3)
        XCTAssertEqual(s.longestSec, 9.4)
        XCTAssertEqual([s.wonUs, s.wonThem], [2, 1])
        XCTAssertEqual(s.endings, [.init(ending: .out, count: 2), .init(ending: .net, count: 1)])
        XCTAssertEqual(s.sourceLine, "From your tags, 3 of 5")
        XCTAssertEqual(s.checkedLine, "3 of 5 checked")
        XCTAssertEqual(s.untagged, 2)
        XCTAssertEqual(RacketTagSummary.seconds(9.4), "9.4 s")
    }

    func testRalliesOnlyPlaybackAndOverlay() {
        let rs = [RacketRally(startSec: 10, endSec: 15, winner: .us, ending: .out),
                  RacketRally(startSec: 20, endSec: 25, winner: .them)]
        XCTAssertEqual(RacketPlaybackPolicy.ralliesOnly(at: 0, rallies: rs), .to(10))
        XCTAssertNil(RacketPlaybackPolicy.ralliesOnly(at: 12, rallies: rs))
        XCTAssertEqual(RacketPlaybackPolicy.ralliesOnly(at: 16, rallies: rs), .to(20))
        XCTAssertEqual(RacketPlaybackPolicy.ralliesOnly(at: 26, rallies: rs), .end)
        XCTAssertEqual(RacketPlaybackPolicy.clamp(-3, 0, 30), 0)
        let at = RacketPlaybackPolicy.rally(at: 22, in: rs)
        XCTAssertEqual(at?.number, 2)
        let sc = RacketPlaybackPolicy.runningScore(through: 2, in: rs)
        XCTAssertEqual([sc.us, sc.them], [1, 1])
        XCTAssertEqual(RacketPlaybackPolicy.overlayLine(number: 1, rally: rs[0], sides: ("You", "Alex")), "Rally 1 · You won · Out")
    }

    func testTagsCountInHistory() {
        func ex(_ rallies: [RacketRally]) -> SessionExercise {
            var e = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
            e.disciplineRaw = WorkoutDiscipline.racket.rawValue
            var l = RacketRecordingLog(startedAt: .now)
            l.rallies = rallies
            e.racketRecordingLog = l
            return e
        }
        let t = RacketTagTotals.of([ex([RacketRally(startSec: 0, endSec: 8, winner: .us)]),
                                    ex([RacketRally(startSec: 0, endSec: 4, winner: .them), RacketRally(startSec: 5, endSec: 6)])])
        XCTAssertEqual(t.marked, 3)
        XCTAssertEqual(t.tagged, 2)
        XCTAssertEqual(t.pointsWonShare, 0.5)
        XCTAssertEqual(t.longestSec, 8)
        let kpis = ActivityDashboard.tagKPIs([ex([RacketRally(startSec: 0, endSec: 8, winner: .us)])])
        XCTAssertEqual(kpis.map(\.title), ["Rallies tagged", "Points won, your tags", "Longest rally marked"])
        XCTAssertEqual(kpis.first?.value, "1")
        XCTAssertTrue(ActivityDashboard.tagKPIs([ex([])]).isEmpty)
    }

    func testOldLogsDecodeWithoutTheNewFields() throws {
        let old = #"{"startedAt":0,"runs":[],"assets":[],"marks":[{"kindRaw":"newGame","startSec":5}]}"#
        let l = try JSONDecoder().decode(RacketRecordingLog.self, from: Data(old.utf8))
        XCTAssertNil(l.split)
        XCTAssertNil(l.rallies)
        XCTAssertEqual(l.baseIndex, 0)
        XCTAssertEqual(l.quality, .hd1080)
    }
}
