import XCTest
@testable import Snappet

/// Unit tests for the racket player's **Edit mode and Share** (prompt 254, issue #448 part 1): the working copy with Undo /
/// Redo and the change count, trimming against neighbours and the minimum, + Rally's clamp-or-refuse rule, split and
/// merge, tagging through the shared rules, Find rallies merging (never over yours), the ruler and zoom, the rally list,
/// looks (scope and storage), shots at the playhead, and the share plan. No device.
final class RacketEditSessionTests: XCTestCase {

    private func rally(_ a: Double, _ b: Double, _ w: RacketRallyWinner? = nil) -> RacketRally {
        RacketRally(startSec: a, endSec: b, winner: w)
    }

    /// Part 100…200: rallies 110–116 (won), 130–135 (lost), 150–158 (untagged).
    private func session() -> RacketEditSession {
        RacketEditSession(rallies: [rally(130, 135, .them), rally(110, 116, .us), rally(150, 158)], lo: 100, hi: 200)
    }

    private let sides = (us: "You", them: "Alex")

    // MARK: Working copy, Undo / Redo

    func testEditsUndoRedoAndCountChanges() {
        var s = session()
        XCTAssertFalse(s.hasChanges)
        XCTAssertEqual(s.countLine, "3 rallies · 2 tagged")
        let id = s.visible[2].id
        s.toggleWinner(id, .us)
        XCTAssertEqual(s.countLine, "3 rallies · 3 tagged")
        XCTAssertTrue(s.canUndo)
        _ = s.add(170...175)
        XCTAssertEqual(s.changedRallies, 2)
        XCTAssertEqual(s.discardLine, "You changed 2 rallies")
        s.undo()
        XCTAssertEqual(s.visible.count, 3)
        XCTAssertEqual(s.changedRallies, 1)
        XCTAssertTrue(s.canRedo)
        s.redo()
        XCTAssertEqual(s.visible.count, 4)
        s.undo(); s.undo()
        XCTAssertFalse(s.hasChanges, "back to where it opened")
        XCTAssertFalse(s.canUndo)
        // A new edit clears Redo.
        s.toggleWinner(id, .them)
        XCTAssertFalse(s.canRedo)
        XCTAssertEqual(s.discardLine, "You changed 1 rally")
    }

    func testDiscardLineNamesScoreAndLook() {
        var s = session()
        s.setLook(.warm)
        XCTAssertEqual(s.discardLine, "You changed the look")
        s.setScore(0, RacketUnitScore(scoreFor: 11, scoreAgainst: 9))
        s.notRally(s.visible[0].id)
        XCTAssertEqual(s.discardLine, "You changed 1 rally, the score and the look")
        XCTAssertEqual(s.visible.count, 2, "Not a rally hides it")
        XCTAssertEqual(s.rallies.count, 3, "and keeps it, so it isn't marked again")
    }

    func testNoOpEditsAddNoUndoStep() {
        var s = session()
        s.setLook(.original)
        XCTAssertFalse(s.canUndo)
    }

    // MARK: Trim

    func testTrimStopsAtNeighboursAndMinimumLength() {
        var s = session()
        let id = s.visible[1].id   // 130–135
        XCTAssertEqual(s.limits(id, .start), 116...134.5)
        XCTAssertEqual(s.limits(id, .end), 130.5...150)
        XCTAssertEqual(s.trim(id, .start, to: 100), 116, "stops at the rally before")
        XCTAssertEqual(s.trim(id, .end, to: 999), 150, "stops at the rally after")
        XCTAssertEqual(s.trim(id, .start, to: 149.9), 149.5, "keeps the minimum length")
        let first = s.visible[0].id
        XCTAssertEqual(s.trim(first, .start, to: 50), 100, "stops at the part")
    }

    func testNudgesAndALiveDragAreOneUndoStep() {
        var s = session()
        let id = s.visible[0].id   // 110–116
        XCTAssertEqual(s.nudge(id, .start, by: -1), 109)
        XCTAssertEqual(s.nudge(id, .end, by: 0.2)!, 116.2, accuracy: 0.0001)
        s.undo(); s.undo()
        XCTAssertFalse(s.hasChanges)
        s.beginLive()
        for t in stride(from: 110.0, to: 104, by: -0.5) { s.trim(id, .start, to: t) }
        s.endLive()
        XCTAssertEqual(s.rally(id)?.startSec, 104.5)
        s.undo()
        XCTAssertEqual(s.rally(id)?.startSec, 110, "the whole drag undoes at once")
    }

    func testTrimmingAGuessConfirmsIt() {
        var g = rally(170, 175)
        g.sourceRaw = RacketModelSource.raw(id: "placeholder", version: 1)
        var s = RacketEditSession(rallies: [g], lo: 100, hi: 200)
        XCTAssertTrue(s.visible[0].isGuess)
        s.nudge(g.id, .end, by: 1)
        XCTAssertFalse(s.visible[0].isGuess)
    }

    func testCrossedSecondTicks() {
        XCTAssertTrue(RacketEditZoom.crossedSecond(from: 9.9, to: 10.1))
        XCTAssertFalse(RacketEditZoom.crossedSecond(from: 10.1, to: 10.9))
        XCTAssertTrue(RacketEditZoom.crossedSecond(from: 10.1, to: 9.9))
    }

    // MARK: + Rally

    func testMarkIsClampedToItsGapOrRefused() {
        let rs = session().visible
        // Inside the gap 116…130: kept as marked.
        if case .success(let m) = RacketEditMark.finish(start: 118, end: 125, rallies: rs, lo: 100, hi: 200) {
            XCTAssertEqual(m.range, 118...125); XCTAssertFalse(m.clamped)
        } else { XCTFail("fits") }
        // Runs into rally 2 at 130: ends there.
        if case .success(let m) = RacketEditMark.finish(start: 118, end: 133, rallies: rs, lo: 100, hi: 200) {
            XCTAssertEqual(m.range, 118...130); XCTAssertTrue(m.clamped)
        } else { XCTFail("clamped") }
        // Dragged back past rally 1: starts where it ended.
        if case .success(let m) = RacketEditMark.finish(start: 120, end: 112, rallies: rs, lo: 100, hi: 200) {
            XCTAssertEqual(m.range, 116...120); XCTAssertTrue(m.clamped)
        } else { XCTFail("clamped back") }
        XCTAssertEqual(RacketEditMark.canStart(at: 112, rallies: rs), .insideRally)
        XCTAssertNil(RacketEditMark.canStart(at: 117, rallies: rs))
        if case .failure(let p) = RacketEditMark.finish(start: 112, end: 120, rallies: rs, lo: 100, hi: 200) {
            XCTAssertEqual(p, .insideRally)
        } else { XCTFail("inside") }
        if case .failure(let p) = RacketEditMark.finish(start: 129.8, end: 140, rallies: rs, lo: 100, hi: 200) {
            XCTAssertEqual(p, .tooShort, "0.2 s left before rally 2")
        } else { XCTFail("too short") }
        XCTAssertEqual(RacketEditMark.line(start: 118, now: 121.2), "Marking · 3.2 s")
        XCTAssertEqual(RacketEditMark.Problem.insideRally.message, "There’s a rally here already. Move to a gap, then tap + Rally.")
    }

    func testANewRallyReplacesANotARallyStretchUnderIt() {
        var s = session()
        s.notRally(s.visible[1].id)   // 130–135 hidden
        let id = s.add(128...140)
        XCTAssertEqual(s.rallies.filter { !$0.isRally }.count, 0)
        XCTAssertEqual(s.number(of: id), 2)
    }

    // MARK: Split, merge, tags

    func testSplitOnlyInsideARallyAndMergeNext() {
        var s = session()
        XCTAssertNil(s.splittable(at: 120), "not inside a rally")
        XCTAssertNil(s.splittable(at: 110.2), "too close to the start")
        XCTAssertTrue(s.split(at: 113))
        XCTAssertEqual(s.visible.count, 4)
        XCTAssertEqual(s.visible[0].winner, .us, "the first half keeps the tags")
        XCTAssertNil(s.visible[1].winner)
        XCTAssertTrue(s.mergeNext(s.visible[0].id))
        XCTAssertEqual(s.visible.count, 3)
        XCTAssertEqual(s.visible[0].endSec, 116)
        let last = s.visible[2].id
        XCTAssertNil(s.next(after: last))
        XCTAssertFalse(s.mergeNext(last))
    }

    func testTagsFollowTheTagSheetRules() {
        var s = session()
        let id = s.visible[2].id
        s.toggleWinner(id, .us)
        s.toggleEnding(id, .net)
        XCTAssertEqual(s.rally(id)?.ending, .net)
        s.toggleEnding(id, .net)
        XCTAssertNil(s.rally(id)?.ending, "tap again clears")
        s.toggleEnding(id, .letReplay)
        XCTAssertNil(s.rally(id)?.winner, "a let has no winner")
        XCTAssertTrue(s.rally(id)!.isTagged)
        s.toggleWinner(id, .them)
        s.toggleWinner(id, .them)
        XCTAssertNil(s.rally(id)?.winner)
        s.setLastShot(id, "Mia")
        XCTAssertEqual(s.rally(id)?.lastShotBy, "Mia")
    }

    func testShotsAtThePlayhead() {
        var s = session()
        let id = s.visible[0].id
        var shots = RacketShotTagging.adding(to: [], at: 111)
        shots = RacketShotTagging.adding(to: shots, at: 113)
        shots = RacketShotTagging.adding(to: shots, at: 112)
        XCTAssertEqual(shots.map(\.atSec), [111, 112, 113], "kept in time order")
        XCTAssertEqual(shots[0].type, "Serve")
        s.setShots(id, shots)
        XCTAssertEqual(s.rally(id)?.shots?.count, 3)
        s.setShots(id, [])
        XCTAssertNil(s.rally(id)?.shots)
    }

    // MARK: Find rallies

    func testFoundRalliesNeverReplaceOrOverlapYours() {
        var s = session()
        func guess(_ a: Double, _ b: Double) -> RacketRally {
            var g = rally(a, b)
            g.sourceRaw = RacketModelSource.raw(id: "placeholder", version: 1)
            g.confidence = 0.9
            return g
        }
        XCTAssertEqual(s.mergeFound([guess(112, 118), guess(170, 176), guess(185, 190)]), 2)
        XCTAssertEqual(s.visible.count, 5)
        XCTAssertEqual(s.visible.filter(\.isGuess).count, 2)
        XCTAssertEqual(s.visible[0].winner, .us, "yours untouched")
        // A second scan replaces the unconfirmed guesses only.
        XCTAssertEqual(s.mergeFound([guess(171, 177)]), 1)
        XCTAssertEqual(s.visible.filter(\.isGuess).map(\.startSec), [171])
        s.undo()
        XCTAssertEqual(s.visible.filter(\.isGuess).count, 2, "undoable")
    }

    // MARK: Ruler, zoom, list

    func testRulerAndZoom() {
        XCTAssertEqual(RacketEditRuler.step(pointsPerSec: 18), 5, "EditRallies: a label every 5 s")
        XCTAssertEqual(RacketEditRuler.step(pointsPerSec: 2), 60)
        XCTAssertEqual(RacketEditRuler.ticks(from: 481, to: 497, step: 5), [485, 490, 495])
        XCTAssertEqual(RacketEditZoom.initial(visibleWidth: 360), 18)
        XCTAssertEqual(RacketEditZoom.clamp(0.01, visibleWidth: 360, duration: 300), 1.2, accuracy: 0.0001)
        XCTAssertEqual(RacketEditZoom.clamp(9999, visibleWidth: 360, duration: 300), 240, accuracy: 0.0001)
        XCTAssertEqual(RacketPlayerText.tenths(494.27), "08:14.2")
        XCTAssertEqual(RacketPlayerText.tenths(0), "00:00.0")
    }

    func testRallyListFiltersAndNextUntagged() {
        let rs = session().visible
        XCTAssertEqual(RacketEditListFilter.allCases.map { $0.chip(rs) }, ["All 3", "Won 1", "Lost 1", "Untagged 1"])
        let rows = RacketEditList.rows(rs, filter: .all, partStart: 100, sides: sides)
        XCTAssertEqual(rows.map(\.result), ["You won", "Alex won", "Untagged"])
        XCTAssertEqual(rows[0].detail, "00:10 · 6.0 s")
        XCTAssertEqual(RacketEditList.rows(rs, filter: .lost, partStart: 100, sides: sides).map(\.number), [2])
        XCTAssertEqual(RacketEditList.nextUntagged(rs, after: 120)?.startSec, 150)
        XCTAssertEqual(RacketEditList.nextUntagged(rs, after: 160)?.startSec, 150, "wraps round")
    }

    // MARK: Looks

    func testLookScopesResolveAndStore() {
        var log = RacketRecordingLog(startedAt: .now)
        XCTAssertEqual(RacketLookStore.resolve(partStart: 0, log: log, always: nil).look, .original)
        XCTAssertEqual(RacketLookStore.resolve(partStart: 0, log: log, always: .cool).scope, .always)
        RacketLookStore.apply(.warm, scope: .thisVideo, partStart: 0, to: &log)
        XCTAssertEqual(RacketLookStore.resolve(partStart: 0, log: log, always: .cool).look, .warm)
        XCTAssertEqual(RacketLookStore.resolve(partStart: 330, log: log, always: .cool).look, .cool, "another part")
        RacketLookStore.apply(.bw, scope: .wholeMatch, partStart: 330, to: &log)
        XCTAssertEqual(RacketLookStore.resolve(partStart: 0, log: log, always: nil).look, .bw, "the match's look reaches every part")
        XCTAssertNil(log.partLooks)
        RacketLookStore.apply(.vivid, scope: .always, partStart: 0, to: &log)
        XCTAssertNil(log.lookRaw)
        XCTAssertEqual(RacketLookStore.resolve(partStart: 0, log: log, always: .vivid).look, .vivid)
        XCTAssertEqual(RacketLook.allCases.map(\.label), ["Original", "Vivid", "Warm", "Cool", "B&W"])
        XCTAssertEqual(RacketLook.bw.params.saturation, 0)
        XCTAssertLessThan(RacketLook.warm.params.temperature, 6500)
        XCTAssertGreaterThan(RacketLook.cool.params.temperature, 6500)
        XCTAssertEqual(RacketLook.original.params, RacketLook.Params())
    }

    func testScoreFromTagsLine() {
        XCTAssertEqual(RacketEditScoreCopy.fromTags(session().visible, sides: sides),
                       "From your tags: You 1, Alex 1. Done marks the score confirmed.")
    }

    // MARK: Share plan

    func testSharePlanRangesLengthSizeAndSpeed() {
        let rs = session().visible
        let only = RacketSharePlan.make(.ralliesOnly, rallies: rs, position: 120, partStart: 100, partEnd: 200, rate: 0.5,
                                        keepSpeed: false, labels: false, sides: sides, quality: .hd1080)!
        XCTAssertEqual(only.ranges, [109...117, 129...136, 149...159], "padded 1 s each side")
        XCTAssertEqual(only.outputSec, 25)
        XCTAssertEqual(only.summary(), "3 rallies · 0:25")
        XCTAssertEqual(only.sizeLine, "about 25 MB")
        let slow = RacketSharePlan.make(.ralliesOnly, rallies: rs, position: 120, partStart: 100, partEnd: 200, rate: 0.5,
                                        keepSpeed: true, labels: false, sides: sides, quality: .hd1080)!
        XCTAssertEqual(slow.outputSec, 50, "half speed doubles the length")
        let whole = RacketSharePlan.make(.whole, rallies: rs, position: 120, partStart: 100, partEnd: 200, rate: 1,
                                         keepSpeed: true, labels: false, sides: sides, quality: .uhd4k)!
        XCTAssertEqual(whole.summary(), "Whole game · 1:40")
        XCTAssertEqual(whole.speed, 1)
        XCTAssertEqual(whole.estimatedMB, 100 / 60 * 170, accuracy: 0.01)
        let one = RacketSharePlan.make(.rally, rallies: rs, position: 132, partStart: 100, partEnd: 200, rate: 1,
                                       keepSpeed: false, labels: false, sides: sides, quality: nil)!
        XCTAssertEqual(one.ranges, [130...135])
        XCTAssertEqual(one.summary(rallyNumber: 2), "Rally 2 · 0:05")
        XCTAssertNil(RacketSharePlan.make(.rally, rallies: rs, position: 101, partStart: 100, partEnd: 200, rate: 1,
                                          keepSpeed: false, labels: false, sides: sides, quality: nil), "before any rally")
        XCTAssertNil(RacketSharePlan.make(.ralliesOnly, rallies: [], position: 101, partStart: 100, partEnd: 200, rate: 1,
                                          keepSpeed: false, labels: false, sides: sides, quality: nil))
        XCTAssertEqual(RacketSharePlan.speedLine(rate: 0.5, keep: false), "0.5× · off shares at normal speed")
        XCTAssertEqual(RacketSharePlan.speedLine(rate: 1, keep: true), "Playing at 1×")
        XCTAssertEqual(only.progressLine(0.64), "Preparing 3 rallies · 64%")
    }

    func testShareLabelsSitOnTheCopysClock() {
        let rs = session().visible
        let p = RacketSharePlan.make(.ralliesOnly, rallies: rs, position: 120, partStart: 100, partEnd: 200, rate: 0.5,
                                     keepSpeed: true, labels: true, sides: sides, quality: nil)!
        XCTAssertEqual(p.labels.count, 3)
        XCTAssertEqual(p.labels[0].text, "Rally 1 · You won · 1 – 0")
        XCTAssertEqual(p.labels[0].start, 2, accuracy: 0.001, "1 s pad, at half speed")
        XCTAssertEqual(p.labels[1].text, "Rally 2 · Alex won · 1 – 1")
        XCTAssertEqual(p.labels[1].start, (8 + 1) * 2, accuracy: 0.001, "after the first 8 s piece")
        XCTAssertEqual(p.labels[2].text, "Rally 3 · untagged · 1 – 1")
    }
}
