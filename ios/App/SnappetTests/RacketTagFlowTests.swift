import XCTest
@testable import Snappet

/// Unit tests for the **pure** tagging parity logic (prompt 251): the rules sheets, FixRally reasons, shot-by-shot
/// tagging by hand, the tag sheet's running score and serve line, LiveTag's last-rally range, "+ Add a missed rally",
/// game-by-game clips adopted as a log, SplitPhotos' import, the "Sent to ChatGPT" line, and the zero-padded rings.
final class RacketTagFlowTests: XCTestCase {

    // MARK: Rules

    func testRulesFollowEachSportsBoard() {
        let tt = RacketRallyRules.sheet(for: .tableTennis)
        XCTAssertEqual(tt.rows.count, 9)
        XCTAssertEqual(tt.rows.first, .init(what: "Ball misses the table", result: "Point to opponent"))
        XCTAssertEqual(tt.rows.last, .init(what: "Picking up the ball, knocking", result: "Not a rally"))
        XCTAssertEqual(tt.footer, "Snappet may miss these on video. Your tag always wins.")
        XCTAssertEqual(RacketRallyRules.sheet(for: .badminton).footer, "The rally winner serves next. Your tag always wins.")
        XCTAssertEqual(RacketRallyRules.sheet(for: .tennis).rows.count, 7)
        XCTAssertEqual(RacketRallyRules.sheet(for: .pickleball).rows[1].result, "No point: next server, or side-out")
        XCTAssertEqual(RacketRallyRules.sheet(for: .padel).rows[3], .init(what: "Bounced, then wall", result: "Still in play"))
        XCTAssertEqual(RacketRallyRules.sheet(for: .squash).rows[5], .init(what: "Stroke", result: "Point to blocked player"))
        for s in RacketSport.allCases { XCTAssertFalse(RacketRallyRules.sheet(for: s).intro.isEmpty) }
    }

    // MARK: Fix reasons

    func testFixReasonsPerSportAndToggle() {
        XCTAssertEqual(RacketFixReason.allCases.map { $0.label(.tableTennis) },
                       ["Started late", "Ended early", "Wrong table", "Ball pickup"])
        XCTAssertEqual(RacketFixReason.wrongCourt.label(.badminton), "Wrong court")
        XCTAssertEqual(RacketFixReason.pickup.label(.badminton), "Shuttle pickup")
        var raw = RacketFixReason.toggled(nil, .pickup)
        XCTAssertEqual(raw, ["pickup"])
        raw = RacketFixReason.toggled(raw, .startedLate)
        XCTAssertEqual(raw, ["startedLate", "pickup"], "kept in the chips' order")
        raw = RacketFixReason.toggled(raw, .pickup)
        raw = RacketFixReason.toggled(raw, .startedLate)
        XCTAssertNil(raw, "an emptied list goes back to nil")
    }

    func testTaggingKeepsShotsAndFixReasons() {
        var r = RacketRally(startSec: 1, endSec: 5)
        r.shots = [RacketShot(sideRaw: "us", handRaw: "fh", type: "Serve")]
        r.fixReasonsRaw = ["startedLate"]
        let out = RacketRallyMarking.tag([r], id: r.id, winner: .us, ending: .net, lastShotBy: nil, notRally: false)
        XCTAssertEqual(out[0].shots?.count, 1)
        XCTAssertEqual(out[0].fixReasonsRaw, ["startedLate"])
    }

    func testOldRallyDecodesWithoutNewFields() throws {
        let json = #"{"id":"6F1C1C59-1A8E-4E64-9E2B-6B1C5F3C1A11","startSec":1,"endSec":3}"#
        let r = try JSONDecoder().decode(RacketRally.self, from: Data(json.utf8))
        XCTAssertNil(r.shots)
        XCTAssertNil(r.fixReasonsRaw)
    }

    // MARK: Shots

    func testShotsAlternateSidesAndEdit() {
        var shots = RacketShotTagging.adding(to: [])
        XCTAssertEqual(shots[0].side, .us)
        XCTAssertEqual(shots[0].type, "Serve", "the first shot is a serve")
        shots = RacketShotTagging.adding(to: shots)
        XCTAssertEqual(shots[1].side, .them)
        XCTAssertNil(shots[1].type)
        XCTAssertEqual(shots[1].handLabel, "FH")
        shots = RacketShotTagging.toggleHand(shots, id: shots[1].id)
        XCTAssertEqual(shots[1].handLabel, "BH")
        shots = RacketShotTagging.setType(shots, id: shots[1].id, type: "Push")
        XCTAssertEqual(shots[1].type, "Push")
        shots = RacketShotTagging.swapSide(shots, id: shots[1].id)
        XCTAssertEqual(shots[1].side, .us)
        shots = RacketShotTagging.adding(to: shots)
        XCTAssertEqual(shots[2].side, .them, "the next shot is the other side's")
        shots = RacketShotTagging.setPlayer(shots, id: shots[2].id, player: "Jordan")
        XCTAssertEqual(shots[2].player, "Jordan")
        shots = RacketShotTagging.remove(shots, id: shots[0].id)
        XCTAssertEqual(shots.count, 2)
        XCTAssertNil(RacketShotTagging.stored([]))
    }

    func testShotChoicesPerSportComeFromTheBoards() {
        XCTAssertEqual(RacketShotType.choices(for: .tableTennis).prefix(5), ["Serve", "Push", "Topspin", "Block", "Smash"])
        XCTAssertTrue(RacketShotType.choices(for: .padel).contains("Bandeja"))
        XCTAssertTrue(RacketShotType.choices(for: .pickleball).contains("Third-shot drop"))
        XCTAssertTrue(RacketShotType.choices(for: .squash).contains("Boast"))
        for s in RacketSport.allCases { XCTAssertEqual(RacketShotType.choices(for: s).first, "Serve") }
        XCTAssertEqual(RacketShotTagging.players(side: .us, partner: "Mia", opponents: ["Jordan", "Lee"]), ["You", "Mia"])
        XCTAssertEqual(RacketShotTagging.players(side: .them, partner: "Mia", opponents: ["Jordan", "Lee"]), ["Jordan", "Lee"])
    }

    func testFirstRallyToTagShots() {
        var a = RacketRally(startSec: 1, endSec: 3)
        a.shots = [RacketShot(sideRaw: "us", handRaw: "fh", type: "Serve")]
        let b = RacketRally(startSec: 5, endSec: 8)
        XCTAssertEqual(RacketShotTagging.firstToTag([b, a])?.id, b.id)
        XCTAssertEqual(RacketShotTagging.firstToTag([a])?.id, a.id, "all tagged: start on the first")
        XCTAssertNil(RacketShotTagging.firstToTag([]))
    }

    // MARK: Tag sheet score and serve

    func testSoFarCountsTagsBeforeThisRally() {
        let rs = [RacketRally(startSec: 1, endSec: 2, winner: .us), RacketRally(startSec: 3, endSec: 4, winner: .them),
                  RacketRally(startSec: 5, endSec: 6, winner: .us), RacketRally(startSec: 7, endSec: 8)]
        let s = RacketTagScore.soFar(before: rs[3].id, in: rs)
        XCTAssertEqual([s.us, s.them], [2, 1])
        let first = RacketTagScore.soFar(before: rs[0].id, in: rs)
        XCTAssertEqual([first.us, first.them], [0, 0])
    }

    func testServingLineFollowsTheServeRules() {
        // Badminton: the rally winner serves next, from the court of the serving side's score (prompt 252).
        let rs = [RacketRally(startSec: 1, endSec: 2, winner: .them), RacketRally(startSec: 3, endSec: 4)]
        XCTAssertEqual(RacketTagScore.servingLine(sport: .badminton, firstServer: .us, unitIndex: 0, previous: [],
                                                  rallyID: rs[1].id, rallies: rs, sides: ("Us", "Them")), "Them serving, left court")
        XCTAssertEqual(RacketTagScore.servingLine(sport: .badminton, firstServer: .us, unitIndex: 0, previous: [],
                                                  rallyID: rs[0].id, rallies: rs, sides: ("Us", "Them")), "Us serving, right court")
        XCTAssertNil(RacketTagScore.servingLine(sport: .badminton, firstServer: nil, unitIndex: 0, previous: [],
                                                rallyID: rs[0].id, rallies: rs, sides: ("Us", "Them")))
    }

    // MARK: LiveTag

    func testLiveTagRangeIsSinceTheLastTapAtMostTwentySeconds() {
        XCTAssertEqual(RacketLiveTag.range(now: 100, since: 92), 92...100)
        XCTAssertEqual(RacketLiveTag.range(now: 100, since: 40), 80...100, "at most 20 s")
        XCTAssertEqual(RacketLiveTag.range(now: 100, since: 99.5), 98...100, "at least 2 s")
        XCTAssertEqual(RacketLiveTag.range(now: 5, since: nil), 0...5)
    }

    func testLiveTagBoundaryAndAdd() {
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        log.marks = [.init(kindRaw: "point", index: 0, startSec: 50), .init(kindRaw: "moment", startSec: 70)]
        log.rallies = [RacketRally(startSec: 55, endSec: 60)]
        XCTAssertEqual(RacketLiveTag.boundary(log: log, before: 80), 60, "a moment mark isn't a boundary")
        let range = RacketLiveTag.range(now: 80, since: 60)
        XCTAssertEqual(RacketLiveTag.number(of: range, in: log.allRallies), 2)
        let out = RacketLiveTag.add(log.allRallies, range: range, winner: .us, ending: .out, notRally: false)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].winner, .us)
        XCTAssertEqual(out[1].ending, .out)
        XCTAssertTrue(out[1].isTagged)
        let overlapping = RacketLiveTag.add(out, range: 75...80, winner: nil, ending: nil, notRally: true)
        XCTAssertEqual(overlapping.count, 2, "fully inside the last tagged rally: nothing added")
        let notRally = RacketLiveTag.add(out, range: 82...90, winner: .us, ending: nil, notRally: true)
        XCTAssertEqual(notRally.last?.notRally, true)
        XCTAssertNil(notRally.last?.winner)
    }

    func testMachineTagsTheLastRallyOnlyWhileRecording() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var m = RacketRecordingMachine(kind: .match, recording: .everything, stillPlayingMinutes: 60, now: t0)
        _ = m.start(now: t0)
        m.tagLastRally(range: 10...18, winner: .them, ending: .net, notRally: false, now: t0.addingTimeInterval(18))
        XCTAssertEqual(m.log?.allRallies.count, 1)
        XCTAssertEqual(m.log?.allRallies.first?.winner, .them)
        _ = m.end(now: t0.addingTimeInterval(30))
        m.tagLastRally(range: 20...28, winner: .us, ending: nil, notRally: false, now: t0.addingTimeInterval(31))
        XCTAssertEqual(m.log?.allRallies.count, 1, "not after the recording ended")
    }

    // MARK: Add a missed rally

    func testMissedRallyAtThePlayhead() {
        let existing = [RacketRally(startSec: 20, endSec: 25)]
        XCTAssertEqual(RacketMissedRally.make(at: 10, within: 0, 100, existing: existing).map { [$0.startSec, $0.endSec] }, [10, 16])
        XCTAssertEqual(RacketMissedRally.make(at: 17, within: 0, 100, existing: existing).map { [$0.startSec, $0.endSec] }, [17, 20],
                       "shortened to fit before the next rally")
        XCTAssertNil(RacketMissedRally.make(at: 22, within: 0, 100, existing: existing), "inside a rally")
        XCTAssertEqual(RacketMissedRally.make(at: 98, within: 0, 100, existing: []).map { $0.endSec }, 100)
    }

    // MARK: Game-by-game clips

    func testClipsBecomeAGameByGameLog() throws {
        let start = Date(timeIntervalSince1970: 0)
        let log = try XCTUnwrap(RacketClipAdoption.log([
            .init(localIdentifier: "b", offsetSec: 900, durationSec: 500, unitIndex: 1),
            .init(localIdentifier: "a", offsetSec: 100, durationSec: 600, unitIndex: 0),
            .init(localIdentifier: "x", offsetSec: 50, durationSec: 0, unitIndex: nil),
        ], sessionStart: start, drill: false, now: start))
        XCTAssertEqual(log.startedAt, start.addingTimeInterval(100))
        XCTAssertEqual(log.assets.map(\.localIdentifier), ["a", "b"])
        XCTAssertEqual(log.assets.map(\.startSec), [0, 800])
        XCTAssertEqual(log.modeRaw, RacketRecordingMode.byUnit.rawValue)
        let games = log.split?.parts.filter { $0.kind == .game } ?? []
        XCTAssertEqual(games.map(\.setIndex), [0, 1])
        XCTAssertEqual(games.map(\.startSec), [0, 800])
        XCTAssertNil(RacketClipAdoption.log([], sessionStart: start, drill: false, now: start))
        let drill = try XCTUnwrap(RacketClipAdoption.log([.init(localIdentifier: "d", offsetSec: 0, durationSec: 300, unitIndex: 0)],
                                                        sessionStart: start, drill: true, now: start))
        XCTAssertEqual(RacketSplitProposal.drillParts(log: drill).filter { $0.kind == .drillBlock }.count, 1)
    }

    // MARK: SplitPhotos

    func testPhotosImportPlacesLoggedGamesOnTheVideo() {
        let v = Date(timeIntervalSince1970: 10_000)
        let units = [RacketPhotosImport.Unit(index: 0, completedAt: v.addingTimeInterval(700), durationSec: 600),
                     RacketPhotosImport.Unit(index: 1, completedAt: v.addingTimeInterval(1500), durationSec: 650),
                     RacketPhotosImport.Unit(index: 2, completedAt: nil, durationSec: nil)]
        let log = RacketPhotosImport.log(assetID: "A", videoStart: v, durationSec: 1800, units: units, drill: false, findParts: true)
        XCTAssertEqual(log.timelineSec, 1800)
        XCTAssertEqual(log.marks.filter { $0.kind == .newGame }.map(\.startSec), [100, 850])
        XCTAssertEqual(log.marks.filter { $0.kind == .breakStart }.map(\.startSec), [700, 1500])
        let parts = RacketSplitProposal.propose(log: log, format: RacketFormat(sport: .tableTennis, bestOf: 3, pointsTo: 11))
        XCTAssertGreaterThanOrEqual(parts.filter { $0.kind == .game }.count, 2)
        let one = RacketPhotosImport.log(assetID: "A", videoStart: v, durationSec: 1800, units: units, drill: false, findParts: false)
        XCTAssertEqual(one.keptAsOne, true)
        XCTAssertTrue(one.marks.isEmpty)
        let drill = RacketPhotosImport.log(assetID: "A", videoStart: v, durationSec: 1800, units: units, drill: true, findParts: true)
        XCTAssertEqual(drill.marks.filter { $0.kind == .block }.count, 2)
        XCTAssertTrue(RacketPhotosImport.linesUp(videoStart: v, durationSec: 600, sessionStart: v.addingTimeInterval(300), sessionEnd: nil))
        XCTAssertFalse(RacketPhotosImport.linesUp(videoStart: v, durationSec: 600, sessionStart: v.addingTimeInterval(86_400), sessionEnd: nil))
    }

    // MARK: Sent to ChatGPT

    func testAWaitingSendShowsUntilItsReplyComesBack() {
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        let sent = Date(timeIntervalSince1970: 5000)
        log.aiRequests = [RacketAIRequest(appRaw: "chatGPT", kindRaw: "video", sentAt: sent, partStart: 0, partEnd: 600,
                                          clip: RacketAIClip(pieces: []))]
        let req = RacketAIWaiting.request(log, partStart: 0, partEnd: 600)
        XCTAssertNotNil(req)
        XCTAssertEqual(req.map { RacketAIWaiting.lines($0).title }, "Sent to ChatGPT")
        XCTAssertTrue(req.map { RacketAIWaiting.lines($0).detail.hasSuffix("Bring its reply back when it’s ready.") } ?? false)
        XCTAssertNil(RacketAIWaiting.request(log, partStart: 700, partEnd: 900), "another part")
        log.aiImports = [RacketAIImport(appRaw: "chatGPT", appName: "ChatGPT", importedAt: sent.addingTimeInterval(60),
                                        partStart: 0, partEnd: 600, rallies: [])]
        XCTAssertNil(RacketAIWaiting.request(log, partStart: 0, partEnd: 600))
    }

    // MARK: Edit score copy

    func testEditScoreChipsAndSource() {
        let s = RacketUnitScore(scoreFor: 11, scoreAgainst: 9)
        XCTAssertEqual(RacketEditScoreCopy.chip(.confirmed(s), unit: .game, index: 0), "Game 1 · confirmed")
        XCTAssertEqual(RacketEditScoreCopy.chip(.fromWatch(s), unit: .game, index: 1), "Game 2 · unconfirmed")
        XCTAssertEqual(RacketEditScoreCopy.chip(.unconfirmed, unit: .game, index: 2), "Game 3 · no score")
        XCTAssertEqual(RacketEditScoreCopy.chip(nil, unit: .set, index: 0), "Set 1 · no score")
        XCTAssertEqual(RacketEditScoreCopy.source(.fromWatch(s)).line, "From your Watch")
        XCTAssertTrue(RacketEditScoreCopy.source(.fromWatch(s)).unconfirmed)
        XCTAssertFalse(RacketEditScoreCopy.source(.confirmed(s)).unconfirmed)
    }

    // MARK: Rings

    func testBlockAndPausedRingsAreZeroPadded() {
        XCTAssertEqual(RacketClock.ring(.init(word: "Block", tone: .work, seconds: 108, progress: 0.5)), "01:48")
        XCTAssertEqual(RacketClock.ring(.init(word: "Paused", tone: .restPaused, seconds: 108, progress: 0.5)), "01:48")
        XCTAssertEqual(RacketClock.ring(.init(word: "Rest", tone: .rest, seconds: 45, progress: 0.5)), "0:45")
        XCTAssertEqual(RacketClock.ring(.init(word: "Break", tone: .rest, seconds: 45, progress: 0.5)), "0:45")
        XCTAssertEqual(RacketCourtZoneRule.boardDefault.from, 8)
        XCTAssertEqual(RacketCourtZoneRule.boardDefault.to, 4)
    }

    // MARK: Paused frame refresh (device bug: split screens black until the first seek)

    func testAPausedReadyPlayerIsAskedForItsFrameWhenTheLayerAttaches() {
        XCTAssertTrue(RacketPlayerFrameRefresh.shouldRefresh(rate: 0, itemReady: true, layerReady: true, reason: "attached"))
        XCTAssertTrue(RacketPlayerFrameRefresh.shouldRefresh(rate: 0, itemReady: true, layerReady: false, reason: "in window"))
        XCTAssertTrue(RacketPlayerFrameRefresh.shouldRefresh(rate: 0, itemReady: true, layerReady: false, reason: "item ready"))
        XCTAssertTrue(RacketPlayerFrameRefresh.shouldRefresh(rate: 0, itemReady: true, layerReady: false, reason: "layer not ready"))
        XCTAssertFalse(RacketPlayerFrameRefresh.shouldRefresh(rate: 0, itemReady: true, layerReady: true, reason: "layer not ready"))
        XCTAssertFalse(RacketPlayerFrameRefresh.shouldRefresh(rate: 1, itemReady: true, layerReady: false, reason: "attached"),
                       "playing draws its own frames")
        XCTAssertFalse(RacketPlayerFrameRefresh.shouldRefresh(rate: 0, itemReady: false, layerReady: false, reason: "attached"),
                       "not ready: wait for the item's ready event")
    }

    func testAPlayerOpensOnTheFirstFrameNotTheEmptyStart() {
        let segs = [RacketVideoSegment(localIdentifier: "a", assetStart: 0, assetEnd: 19.3, timelineStart: 0.69),
                    RacketVideoSegment(localIdentifier: "b", assetStart: 0, assetEnd: 20, timelineStart: 20.2)]
        XCTAssertEqual(RacketScrub.firstFrame(at: 0, segments: segs, end: 60), 0.69, "the camera started 0.69 s in")
        XCTAssertEqual(RacketScrub.firstFrame(at: 5, segments: segs, end: 60), 5, "video there: stays")
        XCTAssertEqual(RacketScrub.firstFrame(at: 20.0, segments: segs, end: 60), 20.2, "a gap between parts")
        XCTAssertEqual(RacketScrub.firstFrame(at: 50, segments: segs, end: 60), 50, "no video after: stays")
        XCTAssertEqual(RacketScrub.firstFrame(at: 0, segments: segs, end: 0.5), 0, "not past the part's end")
        XCTAssertEqual(RacketScrub.firstFrame(at: 0, segments: [], end: 10), 0)
    }
}
