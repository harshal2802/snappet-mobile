import XCTest
@testable import Snappet

/// Prompt 258: timeouts inside a game. The pure game groups, the six invariants (each reported and repaired), every
/// row of the editor's transition table, a randomised run of editor operations, the played ↔ recording time mapping,
/// and the user's real match (split and saved, Game 4 / break / Game 5 really one game) joined, renumbered and undone.
final class RacketSplitTimeoutTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func part(_ k: RacketPartKind, _ a: Double, _ b: Double, link: Int? = nil,
                      belongs: RacketPartBelongs? = nil) -> RacketVideoPart {
        RacketVideoPart(kind: k, startSec: a, endSec: b, setIndex: link, belongs: belongs)
    }
    private func kinds(_ ps: [RacketVideoPart]) -> [RacketPartKind] { ps.map(\.kind) }
    private func links(_ ps: [RacketVideoPart]) -> [Int?] { ps.map(\.setIndex) }
    private func joined(_ ps: [RacketVideoPart]) -> [[Int]] { ps.map { $0.joinedSetIndexes ?? [] } }
    private func unscored(_ end: Double) -> SetLog { var s = SetLog(completedAt: t0.addingTimeInterval(end)); s.scoreUnconfirmed = true; return s }
    private func scored(_ f: Int, _ a: Int, _ end: Double) -> SetLog {
        var s = SetLog(completedAt: t0.addingTimeInterval(end)); s.scoreFor = f; s.scoreAgainst = a; return s
    }

    /// G(0) B G(1) — the simplest pair a timeout can join.
    private lazy var pair: [RacketVideoPart] = { [part(.game, 0, 100, link: 0), part(.breakTime, 100, 130), part(.game, 130, 250, link: 1)] }()

    // MARK: Groups and naming

    func testGroupsJoinHalvesAcrossTimeouts() {
        let ps = [part(.warmup, 0, 10), part(.game, 10, 100), part(.timeout, 100, 130), part(.game, 130, 200),
                  part(.timeout, 200, 220), part(.game, 220, 300), part(.breakTime, 300, 320), part(.game, 320, 400)]
        let gs = RacketGameGroups.groups(ps)
        XCTAssertEqual(gs.map(\.halves), [[1, 3, 5], [7]], "G T G T G is one game")
        XCTAssertEqual(gs[0].timeouts, [2, 4])
        XCTAssertEqual(RacketGameGroups.playedSec(ps, gs[0]), 90 + 70 + 80)
        XCTAssertTrue(RacketGameGroups.isContinuation(3, in: ps))
        XCTAssertFalse(RacketGameGroups.isContinuation(7, in: ps), "a game after a break is its own game")
        let ords = RacketSplitReview.ordinals(ps)
        XCTAssertEqual([ords[ps[1].id], ords[ps[3].id], ords[ps[5].id], ords[ps[7].id]], [1, 1, 1, 2], "ordinals count games, not halves")
        XCTAssertEqual(RacketSplitReview.name(ps[3], ordinal: 1, unit: .game, continued: true), "Game 1, continued")
        XCTAssertEqual(RacketSplitReview.name(ps[2], ordinal: nil, unit: .game), "Timeout")
        XCTAssertEqual(RacketSplitReview.detail(ps[2], sets: [], unit: .game, isLast: false), "0:30, skipped")
        XCTAssertEqual(RacketSplitReview.detail(ps[3], sets: [], unit: .game, isLast: false, continued: true), "2:10–3:20")
        XCTAssertEqual(RacketSplitReview.status(ps[2]), .skipped)
        XCTAssertEqual(RacketSplitTimeline.tone(ps[2]), .timeout)
    }

    func testTimeoutDecodesAndAnUnknownKindStillFallsBackToNotPlay() throws {
        let p = part(.timeout, 1, 9)
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(RacketVideoPart.self, from: data).kind, .timeout)
        // An older build has no `.timeout`: any raw value it doesn't know reads as Not play (no crash).
        var q = p; q.kindRaw = "somethingNewer"
        XCTAssertEqual(q.kind, .notPlay)
        // Saved data from before prompt 258 (no joinedSetIndexes) decodes unchanged.
        let old = #"{"id":"\#(UUID().uuidString)","kindRaw":"game","startSec":0,"endSec":10,"setIndex":2}"#
        let d = try JSONDecoder().decode(RacketVideoPart.self, from: Data(old.utf8))
        XCTAssertEqual(d.setIndex, 2)
        XCTAssertNil(d.joinedSetIndexes)
        // A set saved before has no suggestion.
        XCTAssertNil(SetLog().suggestedScore)
    }

    // MARK: Invariants: validate reports, normalized repairs

    func testInvariant1TilingAndMinimumLength() {
        let ps = [part(.game, 0, 100), part(.timeout, 100, 102), part(.game, 102, 200)]
        XCTAssertEqual(RacketSplitEditor.validate(ps, duration: 200), [.tooShort(index: 1)])
        let fixed = RacketSplitEditor.normalized(ps, duration: 200)
        XCTAssertTrue(RacketSplitEditor.validate(fixed, duration: 200).isEmpty)
        XCTAssertEqual(kinds(fixed), [.game, .timeout, .game], "a short timeout grows; it doesn't vanish")
        XCTAssertEqual(fixed[1].durationSec, RacketSplitEditor.minPartSec, accuracy: 0.001)
        // Gaps and overlaps close.
        let gappy = [part(.game, 0, 90), part(.breakTime, 100, 130), part(.game, 120, 200)]
        XCTAssertTrue(RacketSplitEditor.validate(RacketSplitEditor.normalized(gappy, duration: 200), duration: 200).isEmpty)
    }

    func testInvariant2BrokenTimeoutsBecomeBreaks() {
        for ps in [[part(.timeout, 0, 50), part(.game, 50, 100)],
                   [part(.game, 0, 50), part(.timeout, 50, 100)],
                   [part(.game, 0, 50), part(.timeout, 50, 60), part(.timeout, 60, 70), part(.game, 70, 100)],
                   [part(.game, 0, 50), part(.timeout, 50, 60), part(.unsure, 60, 100)],
                   [part(.warmup, 0, 50), part(.timeout, 50, 60), part(.game, 60, 100)]] {
            XCTAssertTrue(RacketSplitEditor.validate(ps, duration: 100).contains { if case .misplacedTimeout = $0 { return true }; return false })
            let fixed = RacketSplitEditor.normalized(ps, duration: 100)
            XCTAssertFalse(fixed.contains { $0.kind == .timeout }, "\(kinds(ps))")
            XCTAssertTrue(RacketSplitEditor.validate(fixed, duration: 100).isEmpty)
        }
    }

    func testInvariant3AContinuationIsTheGameAfterATimeout() {
        // There is no flag to disagree: remove the timeout and the later half is a plain game with no link of its own.
        var ps = [part(.game, 0, 50, link: 0), part(.timeout, 50, 60), part(.game, 60, 100)]
        ps[2].joinedSetIndexes = [1]
        XCTAssertTrue(RacketGameGroups.isContinuation(2, in: ps))
        ps[1].kind = .breakTime
        XCTAssertFalse(RacketGameGroups.isContinuation(2, in: ps))
        let fixed = RacketSplitEditor.normalized(ps, duration: 100)
        XCTAssertEqual(RacketGameGroups.groups(fixed).count, 2)
        XCTAssertEqual(links(fixed), [0, nil, 1], "its own logged game comes back as its link")
    }

    func testInvariant4OneLinkPerGameOnItsFirstHalfAndNoDuplicates() {
        let ps = [part(.game, 0, 50, link: 0), part(.timeout, 50, 60), part(.game, 60, 100, link: 1),
                  part(.breakTime, 100, 120, link: 2), part(.game, 120, 200, link: 0)]
        let issues = RacketSplitEditor.validate(ps, duration: 200)
        XCTAssertTrue(issues.contains(.misplacedLink(index: 2)))
        XCTAssertTrue(issues.contains(.misplacedLink(index: 3)))
        XCTAssertTrue(issues.contains(.duplicateLink(index: 4)))
        let fixed = RacketSplitEditor.normalized(ps, duration: 200)
        XCTAssertTrue(RacketSplitEditor.validate(fixed, duration: 200).isEmpty)
        XCTAssertEqual(links(fixed), [0, nil, nil, nil, nil])
        XCTAssertEqual(joined(fixed)[2], [1], "the continuation's own game is kept as joined, not lost")
    }

    func testInvariant5HalvesShareBelongs() {
        let ps = [part(.game, 0, 50, belongs: .thisMatch), part(.timeout, 50, 60), part(.game, 60, 100)]
        XCTAssertEqual(RacketSplitEditor.validate(ps, duration: 100), [.mixedBelongs(index: 2)])
        let fixed = RacketSplitEditor.normalized(ps, duration: 100)
        XCTAssertEqual(fixed[2].belongs, .thisMatch)
    }

    func testInvariant6DrillsNeverHoldATimeout() {
        let ps = [part(.drillBlock, 0, 50, link: 0), part(.timeout, 50, 60), part(.drillBlock, 60, 100, link: 1)]
        XCTAssertTrue(RacketSplitEditor.validate(ps, duration: 100, drill: true).contains(.timeoutInDrill(index: 1)))
        let fixed = RacketSplitEditor.normalized(ps, duration: 100, drill: true)
        XCTAssertEqual(kinds(fixed), [.drillBlock, .rest, .drillBlock])
        XCTAssertEqual(links(fixed), [0, nil, 1])
    }

    // MARK: Transition table

    func testChooseTimeoutJoinsTwoUnscoredGames() {
        let ps = RacketSplitEditor.setKind(pair, id: pair[1].id, kind: .timeout)
        XCTAssertEqual(kinds(ps), [.game, .timeout, .game])
        XCTAssertEqual(links(ps), [0, nil, nil])
        XCTAssertEqual(joined(ps), [[], [], [1]], "Game 2 waits to fold into Game 1 on Save")
        let pv = RacketSplitJoin.preview(before: pair, after: ps, id: pair[1].id, sets: [unscored(100), unscored(250)],
                                         unit: .game, ordinal: { $0 + 1 })
        XCTAssertEqual(pv, .init(title: "Game 1 and Game 2 become one game", scoreLine: "no score yet", needsConfirm: false))
    }

    func testChooseTimeoutWithOneLinkKeepsIt() {
        var p = pair; p[0].setIndex = nil
        let ps = RacketSplitEditor.setKind(p, id: p[1].id, kind: .timeout)
        XCTAssertEqual(links(ps), [1, nil, nil], "only the second half had a game: the group keeps it, on its first half")
        XCTAssertEqual(joined(ps), [[], [], []])
        var q = pair; q[0].setIndex = nil; q[2].setIndex = nil
        XCTAssertEqual(links(RacketSplitEditor.setKind(q, id: q[1].id, kind: .timeout)), [nil, nil, nil])
    }

    func testChooseTimeoutWithTwoScoresAsksFirst() {
        let ps = RacketSplitEditor.setKind(pair, id: pair[1].id, kind: .timeout)
        let sets = [scored(6, 5, 100), scored(5, 3, 250)]
        let pv = RacketSplitJoin.preview(before: pair, after: ps, id: pair[1].id, sets: sets, unit: .game, ordinal: { $0 + 4 })
        XCTAssertEqual(pv?.title, "Game 4 and Game 5 become one game")
        XCTAssertEqual(pv?.scoreLine, "6–5 + 5–3 = 11–8")
        XCTAssertEqual(pv?.needsConfirm, true)
        // One score and one placeholder: nothing scored is joined, so no question.
        let one = RacketSplitJoin.preview(before: pair, after: ps, id: pair[1].id, sets: [scored(6, 5, 100), unscored(250)],
                                          unit: .game, ordinal: { $0 + 1 })
        XCTAssertEqual(one?.needsConfirm, false)
        XCTAssertEqual(one?.scoreLine, "keeps 6–5")
    }

    func testTimeoutIsOfferedOnlyBetweenTwoHalvesOfTheSameKindOfGame() {
        let r = RacketSplitEditor.timeoutReason
        XCTAssertNil(RacketSplitEditor.timeoutBlock(pair, index: 1))
        XCTAssertEqual(RacketSplitEditor.timeoutBlock(pair, index: 0), r, "first part")
        XCTAssertEqual(RacketSplitEditor.timeoutBlock(pair, index: 2), r, "last part")
        let beside = [part(.game, 0, 50), part(.breakTime, 50, 60), part(.warmup, 60, 70), part(.game, 70, 100)]
        XCTAssertEqual(RacketSplitEditor.timeoutBlock(beside, index: 1), r)
        let mixed = [part(.game, 0, 50), part(.breakTime, 50, 60), part(.game, 60, 100, belongs: .thisMatch)]
        XCTAssertEqual(RacketSplitEditor.timeoutBlock(mixed, index: 1), r, "an extra game and this match's game")
        // Blocked: the list doesn't change.
        XCTAssertEqual(RacketSplitEditor.setKind(beside, id: beside[1].id, kind: .timeout), beside)
    }

    func testChooseTimeoutOnAGameBetweenGamesFoldsItsGameIn() {
        let ps = [part(.game, 0, 50, link: 0), part(.game, 50, 60, link: 1), part(.game, 60, 100, link: 2)]
        let out = RacketSplitEditor.setKind(ps, id: ps[1].id, kind: .timeout)
        XCTAssertEqual(links(out), [0, nil, nil])
        XCTAssertEqual(joined(out)[2].sorted(), [1, 2])
        XCTAssertEqual(RacketSplitJoin.preview(before: ps, after: out, id: ps[1].id, sets: [scored(3, 1, 50), scored(2, 2, 60), scored(6, 5, 100)],
                                               unit: .game, ordinal: { $0 + 1 })?.title,
                       "Game 1, Game 2 and Game 3 become one game")
    }

    func testChangingATimeoutBackGivesTheLaterHalfItsGameBack() {
        let joinedPS = RacketSplitEditor.setKind(pair, id: pair[1].id, kind: .timeout)
        let back = RacketSplitEditor.setKind(joinedPS, id: pair[1].id, kind: .breakTime)
        XCTAssertEqual(kinds(back), [.game, .breakTime, .game])
        XCTAssertEqual(links(back), [0, nil, 1])
        XCTAssertEqual(joined(back), [[], [], []])
        // On a saved split (no joined game held) the later half has no link: Save matches or makes its game.
        let saved = [part(.game, 0, 100, link: 0), part(.timeout, 100, 130), part(.game, 130, 250)]
        XCTAssertEqual(links(RacketSplitEditor.setKind(saved, id: saved[1].id, kind: .breakTime)), [0, nil, nil])
    }

    func testAHalfLeavingItsGameHandsTheLinkOn() {
        let ps = [part(.game, 0, 50, link: 0), part(.timeout, 50, 60), part(.game, 60, 100), part(.timeout, 100, 110),
                  part(.game, 110, 150)]
        // The first half (holding the link) becomes a warmup: the link moves to the remaining first half.
        let a = RacketSplitEditor.setKind(ps, id: ps[0].id, kind: .warmup)
        XCTAssertEqual(kinds(a), [.warmup, .breakTime, .game, .timeout, .game])
        XCTAssertEqual(links(a), [nil, nil, 0, nil, nil])
        // A middle half becomes a break: the timeouts beside it become breaks, two plain games remain.
        let b = RacketSplitEditor.setKind(ps, id: ps[2].id, kind: .breakTime)
        XCTAssertEqual(kinds(b), [.game, .breakTime, .breakTime, .breakTime, .game])
        XCTAssertEqual(links(b), [0, nil, nil, nil, nil])
        XCTAssertTrue(RacketSplitEditor.validate(b, duration: 150).isEmpty)
    }

    func testSplitInsideAHalfKeepsThePieceTouchingTheTimeoutInTheGame() {
        var ps = [part(.game, 0, 100, link: 0), part(.timeout, 100, 130), part(.game, 130, 250)]
        ps[2].joinedSetIndexes = [1]
        // First half: the second piece touches the timeout and takes the link; the first piece is a new game.
        let a = RacketSplitEditor.split(ps, id: ps[0].id, at: 40)
        XCTAssertEqual(kinds(a), [.game, .game, .timeout, .game])
        XCTAssertEqual(links(a), [nil, 0, nil, nil])
        XCTAssertEqual(RacketGameGroups.groups(a).map(\.halves), [[0], [1, 3]])
        // Last half: the first piece stays; the detached piece is a new game with no link.
        let b = RacketSplitEditor.split(ps, id: ps[2].id, at: 200)
        XCTAssertEqual(links(b), [0, nil, nil, nil])
        XCTAssertEqual(joined(b), [[], [], [1], []])
        XCTAssertEqual(RacketGameGroups.groups(b).map(\.halves), [[0, 2], [3]])
        // A timeout can't be split.
        XCTAssertEqual(RacketSplitEditor.split(ps, id: ps[1].id, at: 115), ps)
        XCTAssertEqual(RacketSplitEditor.splitBlock(ps, index: 1), RacketSplitEditor.splitTimeoutReason)
        // A plain game keeps its link on the first piece (as before).
        let plain = [part(.game, 0, 100, link: 3)]
        XCTAssertEqual(links(RacketSplitEditor.split(plain, id: plain[0].id, at: 50)), [3, nil])
    }

    func testMergeWithNextOnAHalfMergesTheWholeGame() {
        var ps = [part(.game, 0, 50, link: 0), part(.timeout, 50, 60), part(.game, 60, 100), part(.timeout, 100, 110),
                  part(.game, 110, 150), part(.breakTime, 150, 170)]
        ps[2].joinedSetIndexes = [1]
        XCTAssertNotNil(RacketSplitEditor.mergeNote(ps, index: 2, unit: .game))
        XCTAssertEqual(RacketSplitEditor.mergeNote(ps, index: 0, unit: .game),
                       "Merge with next makes this whole game one part, its 2 timeouts included. Nothing is skipped any more.")
        let m = RacketSplitEditor.mergeWithNext(ps, id: ps[2].id)
        XCTAssertEqual(kinds(m), [.game, .breakTime])
        XCTAssertEqual(m[0].startSec, 0); XCTAssertEqual(m[0].endSec, 150)
        XCTAssertEqual(links(m), [0, nil])
        XCTAssertEqual(joined(m), [[1], []], "its games stay one game")
        // On a timeout: not offered. On the last part: not offered.
        XCTAssertEqual(RacketSplitEditor.mergeWithNext(ps, id: ps[1].id), ps)
        XCTAssertEqual(RacketSplitEditor.mergeBlock(ps, index: 1), RacketSplitEditor.mergeTimeoutReason)
        XCTAssertEqual(RacketSplitEditor.mergeBlock(ps, index: 5), RacketSplitEditor.mergeLastReason)
        // The last half followed by a break: the plain merge (the break joins the half, the game stays grouped).
        let p = RacketSplitEditor.mergeWithNext(ps, id: ps[4].id)
        XCTAssertEqual(kinds(p), [.game, .timeout, .game, .timeout, .game])
        XCTAssertEqual(p.last?.endSec, 170)
        // A break taking over a group's first half hands the link on.
        let pre = [part(.breakTime, 0, 20)] + ps.map { var q = $0; q.startSec += 20; q.endSec += 20; return q }
        let q = RacketSplitEditor.mergeWithNext(pre, id: pre[0].id)
        XCTAssertEqual(kinds(q).prefix(3), [.breakTime, .breakTime, .game])
        XCTAssertEqual(q[2].setIndex, 0)
    }

    func testDraggingATimeoutShrinksItToTheMinimumNotAway() {
        let ps = [part(.game, 0, 100), part(.timeout, 100, 130), part(.game, 130, 250)]
        let out = RacketSplitEditor.setBounds(ps, id: ps[0].id, start: 0, end: 200, duration: 250)
        XCTAssertEqual(out[1].durationSec, RacketSplitEditor.minPartSec, accuracy: 0.001)
        XCTAssertEqual(kinds(out), [.game, .timeout, .game])
    }

    func testBelongsFollowsTheWholeGame() {
        let ps = [part(.game, 0, 50), part(.timeout, 50, 60), part(.game, 60, 100)]
        let out = RacketSplitEditor.setBelongs(ps, id: ps[2].id, belongs: .thisMatch)
        XCTAssertEqual(out.map(\.belongs), [.thisMatch, nil, .thisMatch])
        let prac = RacketSplitEditor.setBelongs(ps, id: ps[2].id, belongs: .practice)
        XCTAssertEqual(kinds(prac), [.game, .breakTime, .unsure])
    }

    // MARK: Randomised

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    func testRandomEditsAlwaysEndValidWithoutLosingCoverageOrDuplicatingGames() {
        var rng = LCG(state: 258)
        let pool: [RacketPartKind] = [.warmup, .game, .game, .game, .breakTime, .timeout, .timeout, .unsure, .notPlay]
        var operations = 0
        for _ in 0..<300 {
            // A random list, repaired, with a link on every game's first half.
            var t = 0.0
            var ps: [RacketVideoPart] = []
            for _ in 0..<Int.random(in: 1...9, using: &rng) {
                let d = Double.random(in: 5...300, using: &rng)
                ps.append(part(pool.randomElement(using: &rng)!, t, t + d,
                               belongs: Bool.random(using: &rng) && Bool.random(using: &rng) ? .thisMatch : nil))
                t += d
            }
            let duration = t
            ps = RacketSplitEditor.normalized(ps, duration: duration)
            var n = 0
            for g in RacketGameGroups.groups(ps) { ps[g.first].setIndex = n; n += 1 }
            XCTAssertTrue(RacketSplitEditor.validate(ps, duration: duration).isEmpty)
            let initial = Set(RacketGameGroups.allLinks(ps))
            for _ in 0..<12 {
                guard let p = ps.randomElement(using: &rng) else { break }
                let before = RacketGameGroups.allLinks(ps).sorted()
                var keepsLinks = true
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    let k = RacketPartKind.editChoices.filter { $0 != .drillBlock && $0 != .rest }.randomElement(using: &rng)!
                    keepsLinks = p.kind != .game || k == .game || k == .timeout
                    ps = RacketSplitEditor.setKind(ps, id: p.id, kind: k)
                case 1:
                    ps = RacketSplitEditor.split(ps, id: p.id, at: Double.random(in: p.startSec...p.endSec, using: &rng))
                case 2:
                    keepsLinks = false
                    ps = RacketSplitEditor.mergeWithNext(ps, id: p.id)
                case 3:
                    let a = Double.random(in: 0...duration, using: &rng)
                    ps = RacketSplitEditor.setBounds(ps, id: p.id, start: a, end: a + Double.random(in: 0...200, using: &rng), duration: duration)
                case 4:
                    let b = RacketPartBelongs.allCases.randomElement(using: &rng)!
                    keepsLinks = b == .thisMatch || p.kind != .game
                    ps = RacketSplitEditor.setBelongs(ps, id: p.id, belongs: b)
                default:
                    // Undo a timeout, or choose one where allowed.
                    if p.kind == .timeout { ps = RacketSplitEditor.setKind(ps, id: p.id, kind: .breakTime) }
                    else { ps = RacketSplitEditor.setKind(ps, id: p.id, kind: .timeout) }
                }
                operations += 1
                let issues = RacketSplitEditor.validate(ps, duration: duration)
                XCTAssertTrue(issues.isEmpty, "\(issues) after \(kinds(ps))")
                XCTAssertEqual(ps.first?.startSec ?? -1, 0, accuracy: 0.001)
                XCTAssertEqual(ps.last?.endSec ?? -1, duration, accuracy: 0.001)
                let after = RacketGameGroups.allLinks(ps)
                XCTAssertEqual(after.count, Set(after).count, "a logged game linked twice")
                XCTAssertTrue(Set(after).isSubset(of: initial), "a link appeared from nowhere")
                if keepsLinks { XCTAssertEqual(after.sorted(), before, "lost a game link: \(kinds(ps))") }
                if issues.isEmpty == false { return }
            }
        }
        XCTAssertGreaterThanOrEqual(operations, 3000)
    }

    // MARK: Played time ↔ recording time

    func testPlayedTimeMapsBothWaysAndSkipsTimeouts() {
        let c = RacketPlayedTime(start: 100, end: 400, skips: [300...350, 200...230])
        XCTAssertEqual(c.skips, [200...230, 300...350])
        XCTAssertEqual(c.playedSec, 220)
        XCTAssertEqual(c.played(100), 0)
        XCTAssertEqual(c.played(150), 50)
        XCTAssertEqual(c.played(215), 100, "inside a timeout reads as its start")
        XCTAssertEqual(c.played(200), 100, "an edge is the same played moment on both sides")
        XCTAssertEqual(c.played(230), 100)
        XCTAssertEqual(c.played(260), 130)
        XCTAssertEqual(c.played(400), 220)
        XCTAssertEqual(c.recording(0), 100)
        XCTAssertEqual(c.recording(50), 150)
        XCTAssertEqual(c.recording(100), 230, "played → recording lands after the timeout")
        XCTAssertEqual(c.recording(130), 260)
        XCTAssertEqual(c.recording(170), 350)
        XCTAssertEqual(c.recording(220), 400)
        for p in stride(from: 0.0, through: 220, by: 7.5) { XCTAssertEqual(c.played(c.recording(p)), p, accuracy: 0.001) }
        XCTAssertEqual(c.landing(210), 230)
        XCTAssertEqual(c.landing(210, forward: false), 200)
        XCTAssertEqual(c.landing(150), 150)
        XCTAssertEqual(c.step(from: 195, by: 10), 235, "+10 s across a timeout")
        XCTAssertEqual(c.step(from: 235, by: -10), 195, "−10 s back across it")
        XCTAssertNil(RacketPlayedTime(start: 0, end: 10).skip(at: 5))
    }

    func testRalliesInsideATimeoutAreNotTheGames() {
        let skips = [100.0...130.0]
        XCTAssertTrue(RacketGameGroups.inGame(RacketRally(startSec: 90, endSec: 99), skips: skips))
        XCTAssertFalse(RacketGameGroups.inGame(RacketRally(startSec: 110, endSec: 115), skips: skips))
        XCTAssertTrue(RacketGameGroups.inGame(RacketRally(startSec: 95, endSec: 103), skips: skips), "mostly before the timeout")
        XCTAssertFalse(RacketGameGroups.inGame(RacketRally(startSec: 98, endSec: 110), skips: skips), "mostly inside")
        XCTAssertTrue(RacketGameGroups.inGame(RacketRally(startSec: 128, endSec: 140), skips: skips), "mostly after")
    }

    // MARK: The user's match: split and saved, then Game 4 + Game 5 joined across a timeout

    private func match(scored: Bool) -> SessionExercise {
        let m = RacketVideoSeed.splitTimeoutMatch(startedAt: t0, scored: scored)
        var e = SessionExercise(exerciseId: "x", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: m.sets)
        e.disciplineRaw = WorkoutDiscipline.racket.rawValue
        e.racketSportRaw = RacketSport.tableTennis.rawValue
        e.racketModeRaw = RacketMode.match.rawValue
        e.racketBestOf = 7
        e.racketRecordingLog = m.log
        return e
    }

    /// What the review screen does on Apply.
    private func save(_ e: inout SessionExercise, _ parts: [RacketVideoPart]) -> RacketSplitCommit.Outcome {
        let l = e.racketRecordingLog!
        let out = RacketSplitCommit.apply(parts: parts, sets: e.sets, base: l.baseIndex, startedAt: l.startedAt,
                                          duration: l.timelineSec, rallies: l.allRallies)
        e.sets = out.sets
        e.racketRecordingLog?.split = RacketSplit(parts: out.parts, appliedAt: t0)
        return out
    }

    func testTheUsersMatchUnscoredJoinRenumbersAndUndoes() throws {
        var e = match(scored: false)
        let saved = e.racketRecordingLog!.split!.parts
        XCTAssertEqual(RacketVideoRows.rows(for: e).map(\.title), ["Game 1", "Game 2", "Game 3", "Game 4", "Game 5", "Game 6"])
        let sixth = e.sets[5]

        // Re-open the saved split and choose Timeout for the break between Game 4 and Game 5.
        let breakID = saved[6].id
        XCTAssertNil(RacketSplitEditor.timeoutBlock(saved, index: 6))
        let draft = RacketSplitEditor.setKind(saved, id: breakID, kind: .timeout)
        let pv = RacketSplitJoin.preview(before: saved, after: draft, id: breakID, sets: e.sets, unit: .game, ordinal: { $0 + 1 })
        XCTAssertEqual(pv?.title, "Game 4 and Game 5 become one game")
        XCTAssertEqual(pv?.needsConfirm, false, "two games with no score: the empty one folds in, no question")
        // Cancel: nothing was saved, the match is exactly as it was.
        XCTAssertEqual(e.racketRecordingLog!.split!.parts, saved)

        let out = save(&e, draft)
        XCTAssertEqual(out.added, 0)
        XCTAssertEqual(e.sets.count, 5, "the match loses one game")
        let parts = e.racketRecordingLog!.split!.parts
        XCTAssertEqual(kinds(parts), [.warmup, .game, .game, .game, .breakTime, .game, .timeout, .game, .game, .notPlay])
        XCTAssertEqual(links(parts), [nil, 0, 1, 2, nil, 3, nil, nil, 4, nil], "Game 6 is now Game 5, still its own game")
        XCTAssertEqual(e.sets[4], sixth)
        XCTAssertEqual(out.remap, [0: 0, 1: 1, 2: 2, 3: 3, 4: 3, 5: 4])
        XCTAssertEqual(e.sets[3].durationSec, 480 + 410, "played time")
        XCTAssertEqual(e.sets[3].racketScoreState, .unconfirmed)
        XCTAssertNil(e.sets[3].suggestedScore)
        XCTAssertTrue(RacketSplitEditor.validate(parts, duration: 4000).isEmpty)

        // Your videos: one row per game; the joined game's length is played time; its rallies leave the timeout out.
        let rows = RacketVideoRows.rows(for: e)
        XCTAssertEqual(rows.map(\.title), ["Game 1", "Game 2", "Game 3", "Game 4", "Game 5"])
        XCTAssertEqual(rows[3].startSec, 2220); XCTAssertEqual(rows[3].endSec, 3300)
        XCTAssertEqual(rows[3].line, "14:50 · 1 timeout skipped")
        XCTAssertEqual(rows[3].rallies, 5, "Game 5's rallies moved in, times unchanged; the one in the timeout doesn't count")
        XCTAssertEqual(rows[3].setIndex, 3)
        XCTAssertEqual(rows[4].setIndex, 4)
        XCTAssertEqual(RacketVideoRows.recapLine(e), "5 videos · 5 rallies tagged")
        let log = e.racketRecordingLog!
        XCTAssertEqual(log.rallies(2220, 3300).count, 5)
        XCTAssertEqual(log.timeouts(from: 2220, to: 3300), [2700...2890])
        XCTAssertEqual(log.playedTime(2220, 3300).playedSec, 890)

        // Split review / assign / done read one game.
        XCTAssertEqual(RacketSplitAssign.missingScore(parts: parts, sets: e.sets, unit: .game)?.line, "Game 4 has video but no score")
        XCTAssertEqual(RacketSplitReview.ordinals(parts)[parts[7].id], 4)

        // Undo later: the timeout back to a break gives two games; Game 5 comes back "Score unconfirmed" with a
        // suggestion from its tags.
        let undo = RacketSplitEditor.setKind(parts, id: parts[6].id, kind: .breakTime)
        _ = save(&e, undo)
        XCTAssertEqual(e.sets.count, 6)
        let back = e.racketRecordingLog!.split!.parts
        XCTAssertEqual(links(back), [nil, 0, 1, 2, nil, 3, nil, 4, 5, nil])
        XCTAssertEqual(e.sets[4].racketScoreState, .unconfirmed)
        XCTAssertEqual(e.sets[4].suggestedScore?.label, "1–1", "them, you")
        XCTAssertEqual(e.sets[5], sixth, "Game 6 is Game 6 again")
        XCTAssertEqual(RacketVideoRows.rows(for: e).map(\.title).count, 6)
        XCTAssertEqual(RacketVideoRows.rows(for: e)[4].rallies, 2)
    }

    func testTheUsersMatchScoredJoinSumsAndStaysUnconfirmed() {
        var e = match(scored: true)
        let saved = e.racketRecordingLog!.split!.parts
        let draft = RacketSplitEditor.setKind(saved, id: saved[6].id, kind: .timeout)
        let pv = RacketSplitJoin.preview(before: saved, after: draft, id: saved[6].id, sets: e.sets, unit: .game, ordinal: { $0 + 1 })
        XCTAssertEqual(pv, .init(title: "Game 4 and Game 5 become one game", scoreLine: "6–5 + 5–3 = 11–8", needsConfirm: true))
        XCTAssertEqual(e.racketUnits.count, 5, "before: three games, 6–5 and 5–3 count")
        _ = save(&e, draft)
        XCTAssertEqual(e.sets.count, 5)
        XCTAssertEqual(e.sets[3].racketScoreState, .unconfirmed, "the joined score waits to be confirmed")
        XCTAssertEqual(e.sets[3].suggestedScore?.label, "11–8")
        XCTAssertEqual(e.racketUnits.count, 3, "it counts for neither side until confirmed")
        XCTAssertEqual(RacketVideoRows.rows(for: e)[3].line, "11–8? · 14:50 · 1 timeout skipped")
        XCTAssertEqual(RacketVideoRows.rows(for: e)[3].scoreChip, "Unconfirmed")
        // Confirming it in Edit score clears the suggestion.
        var s = SetLog(); s.scoreFor = 11; s.scoreAgainst = 8
        RacketScoreEdit.apply(s, to: &e.sets[3])
        XCTAssertNil(e.sets[3].suggestedFor)
        XCTAssertEqual(e.sets[3].racketScoreState, .confirmed(RacketUnitScore(scoreFor: 11, scoreAgainst: 8)))
    }

    func testAJoinedGamePlaysFromItsSavedHalvesAfterTheOriginalIsDeleted() {
        var e = match(scored: false)
        var parts = e.racketRecordingLog!.split!.parts
        parts = RacketSplitEditor.setKind(parts, id: parts[6].id, kind: .timeout)
        _ = save(&e, parts)
        var log = e.racketRecordingLog!
        log.assets = [.init(localIdentifier: "orig", startSec: 0, durationSec: 4000)]
        let plan = RacketVideoSpace.deletePlan(log: log)
        XCTAssertFalse(plan.parts.contains { $0.kind == .timeout }, "timeouts are not kept")
        XCTAssertEqual(plan.parts.count, 6, "six game halves (five games) — each half its own video")
        log.derived = plan.parts.map { RacketDerivedVideo(localIdentifier: "d\($0.startSec)", startSec: $0.startSec, endSec: $0.endSec) }
        log.originalDeleted = true
        let segs = RacketVideoMap.segments(start: 2220, end: 3300, log: log)
        XCTAssertEqual(segs.map(\.localIdentifier), ["d2220.0", "d2890.0"], "one game from its two saved videos")
        XCTAssertEqual(segs.map(\.timelineStart), [2220, 2890], "rally positions stay on the recording's clock")
    }

    // MARK: Prompt 258 small rules

    func testPlayStartsAtThePlayheadInsideThePartElseAtItsStart() {
        XCTAssertEqual(RacketScrub.playStart(playhead: 50, start: 10, end: 100), 50)
        XCTAssertEqual(RacketScrub.playStart(playhead: 100, start: 10, end: 100), 10, "end handle moved: the playhead sits on the end")
        XCTAssertEqual(RacketScrub.playStart(playhead: 99.8, start: 10, end: 100), 10, "less than 0.3 s before the end")
        XCTAssertEqual(RacketScrub.playStart(playhead: 5, start: 10, end: 100), 10, "before the part")
        XCTAssertEqual(RacketScrub.playStart(playhead: 10, start: 10, end: 100), 10)
        // After "Split here" at 40 the sheet stays on the first half (10–40) and the playhead is on its end.
        XCTAssertEqual(RacketScrub.playStart(playhead: 40, start: 10, end: 40), 10)
    }

    func testTheReviewSuggestsATimeoutWhenOnlyOneSideHasAScore() {
        let sets = [scored(11, 9, 100), unscored(250)]
        XCTAssertEqual(RacketTimeoutSuggestion.ask(pair, index: 1, sets: sets, unit: .game), "Was this a timeout in Game 1?")
        XCTAssertNil(RacketTimeoutSuggestion.ask(pair, index: 1, sets: [scored(11, 9, 100), scored(5, 3, 250)], unit: .game))
        XCTAssertNil(RacketTimeoutSuggestion.ask(pair, index: 1, sets: [unscored(100), unscored(250)], unit: .game))
        XCTAssertNil(RacketTimeoutSuggestion.ask(pair, index: 0, sets: sets, unit: .game))
        let yes = RacketSplitEditor.setKind(pair, id: pair[1].id, kind: .timeout)
        XCTAssertEqual(kinds(yes), [.game, .timeout, .game])
    }
}
