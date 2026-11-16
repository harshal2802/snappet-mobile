import XCTest
@testable import Snappet

/// Prompt 260: "Edit match". Every row of the editor's transition table, every invariant (reported by `validate`,
/// repaired by `normalized`), the user's real case (a stray 9–11 before the recording), the duration rule for the
/// stop-sheet game, heart rate following its game, media following its game, and a randomised run of a few thousand
/// operation sequences on random matches.
final class RacketMatchEditorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func game(_ f: Int?, _ a: Int?, end: Double, duration: Double? = nil, watch: Bool = false) -> SetLog {
        var s = SetLog(completedAt: t0.addingTimeInterval(end), durationSec: duration)
        s.scoreFor = f; s.scoreAgainst = a
        if f == nil { s.scoreUnconfirmed = true }
        if watch { s.scoreFromWatch = true }
        return s
    }

    private func match(sets: [SetLog], log: RacketRecordingLog? = nil, bestOf: Int = 5) -> SessionExercise {
        var ex = SessionExercise(exerciseId: RacketStats.matchExerciseId(.tableTennis), targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: sets, displayName: RacketStats.matchActivityName(.tableTennis),
                                 kindRaw: SetKind.duration.rawValue)
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        ex.racketSportRaw = RacketSport.tableTennis.rawValue
        ex.racketModeRaw = RacketMode.match.rawValue
        ex.opponent = "Alex"
        ex.racketBestOf = bestOf
        ex.racketRecordingLog = log
        return ex
    }

    /// The user's real case (the seed's fixture): stray 9–11 at set 0, then the recording's three games.
    private func realCase() -> SessionExercise {
        let m = RacketVideoSeed.strayGameMatch(recordingStart: t0)
        return match(sets: m.sets, log: m.log)
    }

    /// A recording split as `kinds` (each 100 s), every game group linked in order starting at `base`.
    private func recorded(_ kinds: [RacketPartKind], base: Int = 0, pre: [SetLog] = []) -> SessionExercise {
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = base
        var parts: [RacketVideoPart] = []
        for (k, kind) in kinds.enumerated() {
            parts.append(RacketVideoPart(kind: kind, startSec: Double(k) * 100, endSec: Double(k + 1) * 100))
        }
        var sets = pre
        for g in RacketGameGroups.groups(parts) {
            parts[g.first].setIndex = sets.count
            sets.append(game(11, sets.count % 2 == 0 ? 7 : 13, end: parts[g.last].endSec,
                             duration: RacketGameGroups.playedSec(parts, g)))
        }
        log.runs = [.init(startSec: 0, endSec: Double(kinds.count) * 100, endReasonRaw: nil)]
        log.endedAt = t0.addingTimeInterval(Double(kinds.count) * 100)
        log.split = RacketSplit(parts: parts, appliedAt: t0.addingTimeInterval(9999))
        log.rallies = parts.indices.filter { parts[$0].kind == .game }.map {
            RacketRally(startSec: parts[$0].startSec + 20, endSec: parts[$0].startSec + 28, winner: .us)
        }
        return match(sets: sets, log: log, bestOf: 0)
    }

    private func committed(_ d: RacketMatchDraft, _ ex: SessionExercise) -> SessionExercise {
        var out = ex
        let c = RacketMatchEditor.commit(d, log: ex.racketRecordingLog)
        out.sets = c.sets
        out.racketRecordingLog = c.log
        d.details.apply(to: &out)
        return out
    }

    /// Every index the saved match stores points at a real game, once, in video order, and the split is valid.
    private func assertConsistent(_ ex: SessionExercise, file: StaticString = #filePath, line: UInt = #line) {
        guard let log = ex.racketRecordingLog else { return }
        let n = ex.sets.count
        XCTAssertTrue((0...n).contains(log.baseIndex), "base \(log.baseIndex) of \(n)", file: file, line: line)
        if let split = log.split, split.appliedAt != nil {
            let issues = RacketMatchEditor.linkIssues(split.parts, duration: max(log.timelineSec, split.parts.last?.endSec ?? 0))
            XCTAssertTrue(issues.isEmpty, "\(issues)", file: file, line: line)
            let links = split.parts.compactMap(\.setIndex)
            XCTAssertEqual(links.count, Set(links).count, "a game linked twice", file: file, line: line)
            XCTAssertTrue(links.allSatisfy { $0 >= log.baseIndex && $0 < n }, "dangling link \(links) base \(log.baseIndex) n \(n)", file: file, line: line)
            XCTAssertEqual(links, links.sorted(), "video order", file: file, line: line)
            XCTAssertTrue(split.parts.allSatisfy { $0.joinedSetIndexes == nil }, file: file, line: line)
            for g in RacketGameGroups.groups(split.parts) {
                XCTAssertNotNil(split.parts[g.first].setIndex, "an unlinked game", file: file, line: line)
            }
        }
        let marks = log.marks.filter { $0.kind == .game }.compactMap(\.index)
        XCTAssertTrue(marks.allSatisfy { $0 >= 0 && $0 < n }, "dangling mark", file: file, line: line)
        XCTAssertEqual(marks.count, Set(marks).count, file: file, line: line)
    }

    // MARK: The real case

    func testRealCaseRemovingTheStrayGameGivesThreeGamesZeroThree() {
        let ex = realCase()
        XCTAssertEqual(ex.racketState.shortResult, "L 0–4", "what the recap showed")
        let d = RacketMatchEditor.draft(from: ex)
        XCTAssertTrue(RacketMatchEditor.validate(d).isEmpty)
        XCTAssertFalse(d.hasVideo(d.games[0].id), "the stray game has no video")
        XCTAssertNil(RacketMatchEditor.removeBlock(d, game: d.games[0].id))
        XCTAssertFalse(RacketMatchEditor.removeNeedsChoice(d, game: d.games[0].id), "no question for a game with no video")
        let after = RacketMatchEditor.remove(d, game: d.games[0].id)
        XCTAssertTrue(RacketMatchEditor.validate(after).isEmpty)
        let saved = committed(after, ex)
        XCTAssertEqual(saved.sets.count, 3)
        XCTAssertEqual(saved.racketState.shortResult, "L 0–3")
        XCTAssertEqual(saved.racketRecordingLog?.baseSetIndex, 0)
        XCTAssertEqual(saved.racketRecordingLog?.split?.parts.map(\.setIndex), [0, 1, 2, nil])
        XCTAssertEqual(saved.racketRecordingLog?.allRallies, ex.racketRecordingLog?.allRallies, "tags intact")
        XCTAssertEqual(saved.racketRecordingLog?.split?.parts.map(\.startSec), ex.racketRecordingLog?.split?.parts.map(\.startSec))
        XCTAssertEqual(saved.racketRecordingLog?.runs, ex.racketRecordingLog?.runs, "recording times never change")
        XCTAssertEqual(saved.sets[2].durationSec, 211, "the stop-sheet game takes its video's time")
        XCTAssertEqual(saved.sets[0].durationSec, 270)
        XCTAssertEqual(RacketVideoRows.rows(for: saved).map(\.title), ["Game 1", "Game 2", "Game 3"])
        XCTAssertEqual(RacketVideoRows.rows(for: saved).map(\.setIndex), [0, 1, 2])
        XCTAssertEqual(RacketVideoRows.rows(for: saved).map(\.tagLine), ["3 marked by you", "3 marked by you", "3 marked by you"])
        XCTAssertEqual(RacketStats.summary([saved])?.units, 3, "session set count")
        XCTAssertEqual(RacketStats.record([saved]).label, RacketStats.record([ex]).label, "still one loss")
        assertConsistent(saved)
    }

    func testRealCaseHeartRateFollowsEachGameAfterRenumbering() {
        let ex = realCase()
        let before = RacketStats.unitWindows(ex, sessionStart: t0.addingTimeInterval(-600))
        let d = RacketMatchEditor.draft(from: ex)
        let saved = committed(RacketMatchEditor.remove(d, game: d.games[0].id), ex)
        let after = RacketStats.unitWindows(saved, sessionStart: t0.addingTimeInterval(-600))
        XCTAssertEqual(after.map(\.index), [0, 1, 2])
        // Games 1 and 2 keep their windows; game 3's no longer reaches back over the whole recording.
        XCTAssertEqual(after[0].start, before[1].start, accuracy: 0.001)
        XCTAssertEqual(after[1].start, before[2].start, accuracy: 0.001)
        XCTAssertEqual(after[2].end, before[3].end, accuracy: 0.001)
        XCTAssertEqual(after[2].end - after[2].start, 211, accuracy: 0.001)
        XCTAssertEqual(before[3].end - before[3].start, 792, accuracy: 0.001, "the bug: the whole recording")
    }

    func testCancelLeavesTheMatchAndAnUntouchedSaveOnlyRepairs() {
        let ex = realCase()
        let stored = ex
        var d = RacketMatchEditor.draft(from: ex)
        d = RacketMatchEditor.remove(d, game: d.games[0].id)
        d.details.opponent = "Someone else"
        // Cancel = the draft is dropped; nothing reads it back into the match.
        XCTAssertEqual(ex, stored)
        // Save with no change writes the same match, except the repaired stop-sheet length.
        var expected = ex
        expected.sets[3].durationSec = 211
        XCTAssertEqual(committed(RacketMatchEditor.draft(from: ex), ex), expected)
    }

    // MARK: Transition table — 1. Score

    func testScoreConfirmAndUnknown() {
        let ex = match(sets: [game(11, 9, end: 100, watch: true), game(nil, nil, end: 200)])
        var d = RacketMatchEditor.draft(from: ex)
        let a = d.games[0].id, b = d.games[1].id
        XCTAssertNil(RacketMatchEditor.confirmBlock(d, game: a), "a Watch tally can be confirmed")
        d = RacketMatchEditor.confirm(d, game: a)
        XCTAssertEqual(d.games[0].set.racketScoreState, .confirmed(RacketUnitScore(scoreFor: 11, scoreAgainst: 9)))
        XCTAssertEqual(RacketMatchEditor.confirmBlock(d, game: a), "This score is already confirmed.")
        XCTAssertEqual(RacketMatchEditor.confirmBlock(d, game: b), "No score to confirm yet. Enter it above.")
        d.games[1].set.suggestedFor = 11; d.games[1].set.suggestedAgainst = 4
        XCTAssertNil(RacketMatchEditor.confirmBlock(d, game: b), "a suggested score can be confirmed")
        d = RacketMatchEditor.confirm(d, game: b)
        XCTAssertEqual(d.games[1].set.racketScore?.label, "11–4")
        XCTAssertNil(d.games[1].set.scoreUnconfirmed)
        d = RacketMatchEditor.setScore(d, game: b, RacketUnitScore(scoreFor: 8, scoreAgainst: 11))
        XCTAssertEqual(d.games[1].set.racketScoreState, .confirmed(RacketUnitScore(scoreFor: 8, scoreAgainst: 11)))
        d = RacketMatchEditor.markUnknown(d, game: a)
        XCTAssertEqual(d.games[0].set.racketScoreState, .unconfirmed)
        XCTAssertNil(d.games[0].set.suggestedScore)
        XCTAssertTrue(RacketMatchEditor.validate(d).isEmpty)
        let saved = committed(d, ex)
        XCTAssertEqual(saved.racketState.scoreLabel, "0–1", "the unknown game counts for neither side")
    }

    // MARK: 2. Remove

    func testRemoveOnlyGameIsBlockedWithTheRemoveMatchReason() {
        let d = RacketMatchEditor.draft(from: match(sets: [game(11, 3, end: 50)]))
        XCTAssertEqual(RacketMatchEditor.removeBlock(d, game: d.games[0].id), RacketMatchEditor.onlyGameReason)
        XCTAssertEqual(RacketMatchEditor.remove(d, game: d.games[0].id, video: .notPlay), d)
    }

    func testRemoveNoVideoRenumbersLaterGames() {
        let ex = recorded([.game, .breakTime, .game], base: 2, pre: [game(11, 1, end: -50), game(11, 2, end: -40)])
        let d = RacketMatchEditor.draft(from: ex)
        let saved = committed(RacketMatchEditor.remove(d, game: d.games[1].id), ex)
        XCTAssertEqual(saved.sets.map { $0.scoreAgainst }, [1, 7, 13])
        XCTAssertEqual(saved.racketRecordingLog?.baseSetIndex, 1)
        XCTAssertEqual(saved.racketRecordingLog?.split?.parts.map(\.setIndex), [1, nil, 2])
        assertConsistent(saved)
    }

    func testRemoveWithVideoNeedsAChoiceAndKeepsVideoAndRallies() {
        let ex = recorded([.game, .breakTime, .game, .timeout, .game, .notPlay])
        let d = RacketMatchEditor.draft(from: ex)
        let second = d.games[1].id
        XCTAssertTrue(RacketMatchEditor.removeNeedsChoice(d, game: second))
        XCTAssertEqual(RacketMatchEditor.remove(d, game: second), d, "no choice yet: nothing changes")
        XCTAssertEqual(RacketMatchEditor.ralliesInVideo(d, game: second).tagged, 2)
        XCTAssertTrue(RacketMatchEditor.ralliesLine(d, game: second).hasPrefix("2 tagged rallies stop counting toward this match."))

        let extra = committed(RacketMatchEditor.remove(d, game: second, video: .extra), ex)
        XCTAssertEqual(extra.racketRecordingLog?.split?.parts.map(\.kind), [.game, .breakTime, .unsure, .breakTime, .unsure, .notPlay])
        XCTAssertEqual(extra.sets.count, 1)
        XCTAssertEqual(extra.racketRecordingLog?.allRallies, ex.racketRecordingLog?.allRallies)
        assertConsistent(extra)

        let notPlay = committed(RacketMatchEditor.remove(d, game: second, video: .notPlay), ex)
        XCTAssertEqual(notPlay.racketRecordingLog?.split?.parts.map(\.kind), [.game, .breakTime, .notPlay, .notPlay, .notPlay, .notPlay])
        XCTAssertEqual(notPlay.racketRecordingLog?.split?.parts.map(\.startSec), ex.racketRecordingLog?.split?.parts.map(\.startSec),
                       "video is never deleted or moved")
        assertConsistent(notPlay)
    }

    // MARK: 3. Add

    func testAddAtAPositionHasNoVideoAndNeverTakesAPart() {
        let ex = recorded([.game, .breakTime, .game])
        var d = RacketMatchEditor.draft(from: ex)
        d = RacketMatchEditor.add(d, at: 1, fallback: t0)
        XCTAssertEqual(d.games.count, 3)
        XCTAssertFalse(d.hasVideo(d.games[1].id))
        XCTAssertEqual(d.games[1].set.racketScoreState, .unconfirmed)
        XCTAssertTrue(d.games[1].set.completedAt! > d.games[0].set.completedAt!)
        XCTAssertTrue(d.games[1].set.completedAt! < d.games[2].set.completedAt!)
        d = RacketMatchEditor.add(d, at: 0, score: RacketUnitScore(scoreFor: 11, scoreAgainst: 0), fallback: t0)
        XCTAssertEqual(d.base, 1, "a game added before the recording's first game is logged before it")
        let saved = committed(d, ex)
        XCTAssertEqual(saved.racketRecordingLog?.split?.parts.map(\.setIndex), [1, nil, 3])
        XCTAssertEqual(saved.sets[0].racketScore?.label, "11–0")
        assertConsistent(saved)
    }

    // MARK: 4. Move

    func testMoveRules() {
        let ex = recorded([.game, .breakTime, .game], base: 1, pre: [game(11, 1, end: -50)])
        let d = RacketMatchEditor.draft(from: ex)
        let stray = d.games[0].id, g1 = d.games[1].id, g2 = d.games[2].id
        XCTAssertEqual(RacketMatchEditor.moveBlock(d, game: stray, by: -1), RacketMatchEditor.firstReason)
        XCTAssertEqual(RacketMatchEditor.moveBlock(d, game: g2, by: 1), RacketMatchEditor.lastReason)
        XCTAssertEqual(RacketMatchEditor.moveBlock(d, game: g2, by: -1), RacketMatchEditor.videoOrderReason)
        XCTAssertEqual(RacketMatchEditor.move(d, game: g2, by: -1), d)
        XCTAssertNil(RacketMatchEditor.moveBlock(d, game: stray, by: 1))
        let moved = RacketMatchEditor.move(d, game: stray, by: 1)
        XCTAssertEqual(moved.games.map(\.id), [g1, stray, g2])
        XCTAssertEqual(moved.base, 0, "a game with video is always on the recording's side")
        let saved = committed(moved, ex)
        XCTAssertEqual(saved.racketRecordingLog?.split?.parts.map(\.setIndex), [0, nil, 2])
        assertConsistent(saved)
    }

    // MARK: 5. Link / unlink

    func testUnlinkThenLinkAgain() {
        let ex = recorded([.game, .breakTime, .game, .notPlay])
        var d = RacketMatchEditor.draft(from: ex)
        let g1 = d.games[0].id, g2 = d.games[1].id
        XCTAssertEqual(RacketMatchEditor.unlinkBlock(RacketMatchEditor.draft(from: match(sets: [game(1, 11, end: 1)])),
                                                     game: RacketMatchEditor.draft(from: match(sets: [game(1, 11, end: 1)])).games[0].id),
                       RacketMatchEditor.noVideoReason)
        d = RacketMatchEditor.unlink(d, game: g2)
        XCTAssertFalse(d.hasVideo(g2))
        XCTAssertEqual(d.parts.map(\.kind), [.game, .breakTime, .unsure, .notPlay], "its video becomes an extra stretch")
        XCTAssertEqual(d.games.count, 2, "the game stays")
        let candidates = RacketMatchEditor.linkCandidates(d)
        XCTAssertEqual(candidates, [d.parts[2].id])
        XCTAssertEqual(RacketMatchEditor.linkBlock(d, game: g1, part: candidates[0]), RacketMatchEditor.hasVideoLinkReason)
        // A game added before game 1 can't take video that comes after game 1's.
        let early = RacketMatchEditor.add(d, at: 0, fallback: t0)
        XCTAssertEqual(RacketMatchEditor.linkBlock(early, game: early.games[0].id, part: candidates[0]), RacketMatchEditor.linkOrderReason)
        d = RacketMatchEditor.link(d, game: g2, part: candidates[0])
        XCTAssertEqual(d.parts.map(\.kind), [.game, .breakTime, .game, .notPlay])
        XCTAssertEqual(d.games[1].set.durationSec, 100)
        XCTAssertEqual(d.games[1].set.completedAt, t0.addingTimeInterval(300), "logged at its video's end")
        let other = RacketMatchEditor.add(d, at: 2, fallback: t0)
        XCTAssertEqual(RacketMatchEditor.linkBlock(other, game: other.games[2].id, part: d.parts[2].id), RacketMatchEditor.partTakenReason)
        assertConsistent(committed(d, ex))
    }

    // MARK: 6. Details

    func testDetailsAndTheQuietFitNote() {
        let ex = match(sets: [game(11, 3, end: 1), game(11, 4, end: 2), game(5, 11, end: 3)], bestOf: 5)
        var d = RacketMatchEditor.draft(from: ex)
        XCTAssertNil(RacketMatchEditor.fitNote(d))
        d.details.bestOf = 1
        XCTAssertEqual(RacketMatchEditor.fitNote(d), "3 games logged, more than best of 1 allows. Nothing is removed.")
        d.details.bestOf = 3
        XCTAssertEqual(RacketMatchEditor.fitNote(d), "Best of 3 is decided after game 2. The games after it still show.")
        d.details.opponent = "Jo"
        d.details.event = "City Open"
        d.details.round = "QF"
        let saved = committed(d, ex)
        XCTAssertEqual(saved.sets.count, 3, "changing best of never deletes games")
        XCTAssertEqual(saved.opponent, "Jo")
        XCTAssertEqual(saved.racketEvent, "City Open")
        XCTAssertEqual(saved.racketRound, "QF")
        XCTAssertEqual(saved.racketBestOf, 3)
        XCTAssertEqual(saved.racketState.shortResult, "W 2–1")
    }

    // MARK: 7. Move to another match

    func testMoveAGameWithNoVideoToAnotherMatchMovesItsMediaToo() {
        let a = realCase()
        var b = recorded([.game, .breakTime, .game])
        b.opponent = "Sam"
        // b's games end at t0+100 / +300; the stray game (t0−300) arrives first, before b's recording.
        var d = RacketMatchEditor.draft(from: a)
        XCTAssertEqual(RacketMatchEditor.moveToMatchBlock(d, game: d.games[1].id, otherMatches: 1), RacketMatchEditor.moveVideoReason)
        XCTAssertEqual(RacketMatchEditor.moveToMatchBlock(d, game: d.games[0].id, otherMatches: 0), RacketMatchEditor.noOtherMatchReason)
        d = RacketMatchEditor.moveToMatch(d, game: d.games[0].id, to: b.id, otherMatches: 1)
        guard let out = RacketMatchSave.apply(d, to: [a, b], match: a.id) else { return XCTFail("save") }
        let na = out.exercises[0], nb = out.exercises[1]
        XCTAssertEqual(na.sets.count, 3)
        XCTAssertEqual(nb.sets.count, 3)
        XCTAssertEqual(nb.sets[0].durationSec, 6.4)
        XCTAssertEqual(nb.racketRecordingLog?.baseSetIndex, 1)
        XCTAssertEqual(nb.racketRecordingLog?.split?.parts.map(\.setIndex), [1, nil, 2])
        assertConsistent(na)
        assertConsistent(nb)
        // Media: a's photo on the stray game goes to b's game 0; a's game-3 clip to index 2; b's game-1 clip to 2.
        XCTAssertEqual(out.media[a.id]?(0), .init(exerciseID: b.id, setIndex: 0))
        XCTAssertEqual(out.media[a.id]?(3), .init(exerciseID: a.id, setIndex: 2))
        XCTAssertEqual(out.media[b.id]?(1), .init(exerciseID: b.id, setIndex: 2))
    }

    func testRemovedGamesMediaStaysOnTheMatchWithNoGame() {
        let ex = recorded([.game, .breakTime, .game])
        let d = RacketMatchEditor.draft(from: ex)
        let out = RacketMatchSave.apply(RacketMatchEditor.remove(d, game: d.games[0].id, video: .extra), to: [ex], match: ex.id)
        XCTAssertEqual(out?.media[ex.id]?(0), .init(exerciseID: ex.id, setIndex: nil))
        XCTAssertEqual(out?.media[ex.id]?(1), .init(exerciseID: ex.id, setIndex: 0))
    }

    // MARK: 8. Remove match

    func testRemoveMatchLeavesTheOtherMatchUntouched() {
        let a = realCase(), b = recorded([.game, .breakTime, .game])
        let out = SessionSetEditing.removing(a.id, from: [a, b])
        XCTAssertEqual(out, [b])
        assertConsistent(out[0])
    }

    // MARK: Invariants

    func testEachInvariantIsReportedAndRepaired() {
        let ex = recorded([.game, .timeout, .game, .breakTime, .game, .notPlay], base: 1, pre: [game(11, 1, end: -50)])
        let good = RacketMatchEditor.draft(from: ex)
        XCTAssertTrue(RacketMatchEditor.validate(good).isEmpty)
        func check(_ d: RacketMatchDraft, _ issue: (RacketMatchEditor.Issue) -> Bool, _ name: String) {
            XCTAssertTrue(RacketMatchEditor.validate(d).contains(where: issue), "\(name) not reported: \(RacketMatchEditor.validate(d))")
            let fixed = RacketMatchEditor.normalized(d)
            XCTAssertTrue(RacketMatchEditor.validate(fixed).isEmpty, "\(name) not repaired: \(RacketMatchEditor.validate(fixed))")
            XCTAssertEqual(fixed.games.count + fixed.outgoing.count, d.games.count + d.outgoing.count, "\(name): a game was lost")
            XCTAssertEqual(fixed.parts.map(\.startSec), d.parts.map(\.startSec), "\(name): video times moved")
        }
        // 1. dangling and doubled links.
        var d = good; d.links[d.parts[4].id] = UUID()
        check(d, { $0 == .danglingLink }, "dangling")
        d = good; d.links[d.parts[4].id] = d.games[1].id
        check(d, { $0 == .linkedTwice }, "linked twice")
        d = good; d.markLinks[0] = UUID()
        check(d, { $0 == .danglingLink }, "dangling mark")
        // 2. a link on a continuation; an unlinked game group.
        d = good; d.links[d.parts[2].id] = d.games[0].id
        check(d, { $0 == .misplacedLink }, "misplaced")
        d = good; d.links[d.parts[4].id] = nil
        check(d, { $0 == .unlinkedGame }, "unlinked game")
        // 3. video order.
        d = good; d.games.swapAt(1, 2)
        check(d, { $0 == .videoOrder }, "video order")
        // 4. base.
        d = good; d.base = 9
        check(d, { $0 == .baseOutOfRange }, "base")
        d = good; d.base = 2
        check(d, { $0 == .videoBeforeBase }, "video before base")
        // 5. a game longer than its video.
        d = good; d.games[2].set.durationSec = 5000
        check(d, { if case .durationLongerThanVideo = $0 { return true } else { return false } }, "duration")
        // 6. a game with video leaving; a negative score.
        d = good; d.outgoing = [.init(game: d.games.remove(at: 1), to: UUID())]
        XCTAssertTrue(RacketMatchEditor.normalized(d).games.contains { $0.id == good.games[1].id }, "a video game comes back")
        d = good; d.games[0].set.scoreFor = -3
        check(d, { if case .negativeScore = $0 { return true } else { return false } }, "negative")
    }

    // MARK: Matches of every shape

    func testNoRecordingGameByGameDerivedAndOlderBuildReadable() throws {
        // No recording at all.
        let plain = match(sets: [game(11, 3, end: 1), game(3, 11, end: 2)])
        var d = RacketMatchEditor.draft(from: plain)
        d = RacketMatchEditor.move(d, game: d.games[1].id, by: -1)
        XCTAssertNil(committed(d, plain).racketRecordingLog)
        XCTAssertEqual(committed(d, plain).sets.map(\.scoreFor), [3, 11])

        // Game by game (adopted clips work the same: `game` marks + the split built from them), original deleted.
        var log = RacketRecordingLog(startedAt: t0)
        log.baseSetIndex = 0
        log.modeRaw = RacketRecordingMode.byUnit.rawValue
        log.runs = [.init(startSec: 0, endSec: 100, endReasonRaw: nil), .init(startSec: 150, endSec: 260, endReasonRaw: nil)]
        log.marks = [.init(kindRaw: "game", index: 0, startSec: 0, endSec: 100), .init(kindRaw: "game", index: 1, startSec: 150, endSec: 260)]
        log.endedAt = t0.addingTimeInterval(260)
        log.split = RacketGameByGameSplit.split(log, now: t0)
        log.originalDeleted = true
        log.derived = [.init(localIdentifier: "d1", startSec: 0, endSec: 100), .init(localIdentifier: "d2", startSec: 150, endSec: 260)]
        let gbg = match(sets: [game(11, 9, end: 100, duration: 100), game(7, 11, end: 260, duration: 110)], log: log)
        d = RacketMatchEditor.draft(from: gbg)
        d = RacketMatchEditor.add(d, at: 0, fallback: t0)
        d = RacketMatchEditor.remove(d, game: d.games[1].id, video: .notPlay)
        let saved = committed(d, gbg)
        XCTAssertEqual(saved.racketRecordingLog?.marks.map(\.index), [nil, 1])
        XCTAssertEqual(saved.racketRecordingLog?.derived, log.derived, "derived videos untouched")
        XCTAssertEqual(saved.racketRecordingLog?.split?.parts.compactMap(\.setIndex), [1])
        assertConsistent(saved)

        // An older build: no new key and no new raw value in what was written.
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SessionExercise.self, from: data)
        XCTAssertEqual(back, saved)
        let known = Set(["warmup", "game", "breakTime", "drillBlock", "rest", "notPlay", "unsure", "timeout"])
        XCTAssertTrue((saved.racketRecordingLog?.split?.parts ?? []).allSatisfy { known.contains($0.kindRaw) })
        let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gbg.racketRecordingLog)) as? [String: Any] ?? [:]
        let after = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved.racketRecordingLog)) as? [String: Any] ?? [:]
        XCTAssertTrue(Set(after.keys).isSubset(of: Set(before.keys)), "no new keys")
    }

    // MARK: Duration rule (split apply)

    func testStopSheetGameTakesItsPlayedTimeAWatchGameKeepsItsOwn() {
        let parts = [RacketVideoPart(kind: .game, startSec: 0, endSec: 300), RacketVideoPart(kind: .breakTime, startSec: 300, endSec: 400),
                     RacketVideoPart(kind: .game, startSec: 400, endSec: 600), RacketVideoPart(kind: .notPlay, startSec: 600, endSec: 620)]
        // Watch game: logged at its part's end, timed on the wrist (shorter than its video) — kept.
        let watch = game(11, 9, end: 300, duration: 240, watch: true)
        // Stop-sheet game: logged at the end with the whole recording's length — replaced.
        let stop = game(9, 11, end: 620, duration: 620)
        let out = RacketSplitAssign.apply(parts: parts, sets: [watch, stop], base: 0, startedAt: t0)
        XCTAssertEqual(out.sets[0].durationSec, 240)
        XCTAssertEqual(out.sets[1].durationSec, 200)
        // Within the tolerance it stays; no length stays none.
        XCTAssertEqual(RacketGameDuration.fitted(310, span: 300, played: 300), 310)
        XCTAssertEqual(RacketGameDuration.fitted(321, span: 300, played: 290), 290)
        XCTAssertNil(RacketGameDuration.fitted(nil, span: 300, played: 300))
    }

    // MARK: Randomised

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    func testRandomOperationSequencesAlwaysEndValid() {
        var rng = LCG(state: 260)
        let pool: [RacketPartKind] = [.warmup, .game, .game, .game, .breakTime, .timeout, .unsure, .notPlay]
        var sequences = 0
        for _ in 0..<3000 {
            // A random match: maybe a recording (split, timeouts), maybe games before it.
            let pre = (0..<Int.random(in: 0...2, using: &rng)).map { k in game(11, k, end: -100 + Double(k)) }
            var ex: SessionExercise
            let shape = Int.random(in: 0..<3, using: &rng)
            if shape == 2 {
                // Game by game (or adopted clips): `game` marks with gaps between them, the split built from them.
                var log = RacketRecordingLog(startedAt: t0)
                log.baseSetIndex = pre.count
                log.modeRaw = RacketRecordingMode.byUnit.rawValue
                var sets = pre
                var t = 0.0
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    let len = Double.random(in: 30...300, using: &rng)
                    log.runs.append(.init(startSec: t, endSec: t + len, endReasonRaw: nil))
                    log.marks.append(.init(kindRaw: "game", index: sets.count, startSec: t, endSec: t + len))
                    sets.append(game(11, Int.random(in: 0...13, using: &rng), end: t + len, duration: len))
                    t += len + Double.random(in: 0...90, using: &rng)
                }
                log.endedAt = t0.addingTimeInterval(t)
                log.split = RacketGameByGameSplit.split(log, now: t0)
                ex = match(sets: sets, log: log)
            } else if shape == 1 {
                let kinds = (0..<Int.random(in: 1...7, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
                var base = recorded(RacketSplitEditor.normalized(kinds.enumerated().map {
                    RacketVideoPart(kind: $1, startSec: Double($0) * 100, endSec: Double($0 + 1) * 100)
                }, duration: Double(kinds.count) * 100).map(\.kind), base: pre.count, pre: pre)
                if base.sets.isEmpty { base.sets = [game(nil, nil, end: 5)] }
                ex = base
            } else {
                ex = match(sets: pre + [game(11, 4, end: 10), game(nil, nil, end: 20)])
            }
            let other = UUID()
            var d = RacketMatchEditor.draft(from: ex)
            XCTAssertTrue(RacketMatchEditor.validate(d).isEmpty, "start: \(RacketMatchEditor.validate(d))")
            let videoGames = Set(d.games.filter { d.hasVideo($0.id) }.map(\.id))
            var released = Set<UUID>()   // video games the "player" explicitly removed or unlinked
            for _ in 0..<Int.random(in: 1...10, using: &rng) {
                guard let g = d.games.randomElement(using: &rng) else { break }
                switch Int.random(in: 0..<9, using: &rng) {
                case 0: d = RacketMatchEditor.setScore(d, game: g.id, RacketUnitScore(scoreFor: Int.random(in: 0...15, using: &rng), scoreAgainst: Int.random(in: 0...15, using: &rng)))
                case 1: d = RacketMatchEditor.markUnknown(d, game: g.id)
                case 2: d = RacketMatchEditor.confirm(d, game: g.id)
                case 3:
                    let choice: RacketRemovedVideo? = Bool.random(using: &rng) ? RacketRemovedVideo.allCases.randomElement(using: &rng) : nil
                    if d.hasVideo(g.id), choice != nil, RacketMatchEditor.removeBlock(d, game: g.id) == nil { released.insert(g.id) }
                    d = RacketMatchEditor.remove(d, game: g.id, video: choice)
                case 4: d = RacketMatchEditor.add(d, at: Int.random(in: 0...d.games.count, using: &rng), fallback: t0)
                case 5: d = RacketMatchEditor.move(d, game: g.id, by: Bool.random(using: &rng) ? -1 : 1)
                case 6:
                    if d.hasVideo(g.id) { released.insert(g.id); d = RacketMatchEditor.unlink(d, game: g.id) }
                    else if let p = RacketMatchEditor.linkCandidates(d).randomElement(using: &rng) { d = RacketMatchEditor.link(d, game: g.id, part: p) }
                case 7: d = RacketMatchEditor.moveToMatch(d, game: g.id, to: other, otherMatches: 1)
                default: d.details.bestOf = [nil, 1, 3, 5, 7].randomElement(using: &rng)!
                }
                let issues = RacketMatchEditor.validate(d)
                XCTAssertTrue(issues.isEmpty, "\(issues)")
                if !issues.isEmpty { return }
            }
            sequences += 1
            // Never lose a game with video without an explicit choice.
            for id in videoGames where !released.contains(id) {
                XCTAssertTrue(d.hasVideo(id), "a filmed game lost its video silently")
            }
            // Never lose tags or video times.
            let saved = committed(d, ex)
            XCTAssertEqual(saved.racketRecordingLog?.allRallies, ex.racketRecordingLog?.allRallies)
            XCTAssertEqual(saved.racketRecordingLog?.split?.parts.map(\.startSec), ex.racketRecordingLog?.split?.parts.map(\.startSec))
            XCTAssertEqual(saved.sets.count + d.outgoing.count, d.games.count + d.outgoing.count)
            assertConsistent(saved)
        }
        XCTAssertEqual(sequences, 3000)
    }
}
