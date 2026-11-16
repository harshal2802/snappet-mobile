import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for the **Watch-mode racket player** (prompt 253, issue #448 part 1): copy and formatting, the part's
/// rallies (running score, previous / next, loop target), the tap state machine (instant single tap, double-tap skip,
/// streaks), auto-hide, hold for 2×, speeds, loop stepping, zoom / pan clamping, the letterbox hint, the filmstrip's
/// offset ↔ time mapping and drag tolerance, and the rally bands. No device.
final class RacketPlayerWatchTests: XCTestCase {

    private func rally(_ a: Double, _ b: Double, _ w: RacketRallyWinner? = nil) -> RacketRally {
        RacketRally(startSec: a, endSec: b, winner: w)
    }

    /// 0–300 s: rallies at 10–16 (won), 30–35 (lost), 50–58 (untagged), 80–86 (won).
    private var four: RacketPlayerRallies {
        RacketPlayerRallies([rally(80, 86, .us), rally(10, 16, .us), rally(30, 35, .them), rally(50, 58)])
    }

    private let sides = (us: "You", them: "Alex")

    // MARK: Copy

    func testClockAndTimeLineUseTwoDigitMinutes() {
        XCTAssertEqual(RacketPlayerText.clock(494), "08:14")
        XCTAssertEqual(RacketPlayerText.clock(1112), "18:32")
        XCTAssertEqual(RacketPlayerText.clock(3723), "1:02:03")
        XCTAssertEqual(RacketPlayerText.timeLine(494, of: 1112), "08:14 / 18:32")
        XCTAssertEqual(RacketPlayerText.timeLine(2000, of: 1112), "18:32 / 18:32", "never past the end")
        XCTAssertEqual(RacketPlayerText.timeLine(-3, of: 1112), "00:00 / 18:32")
    }

    func testSmallLabels() {
        XCTAssertEqual(RacketPlayerText.seconds(6.24), "6.2 s")
        XCTAssertEqual(RacketPlayerText.score(7, 5), "7 – 5")
        XCTAssertEqual(RacketPlayerSpeed.options.map(RacketPlayerText.speed), ["0.25×", "0.5×", "1×", "1.5×", "2×"])
        XCTAssertEqual(RacketPlayerSpeed.options.map(RacketPlayerSpeed.id), ["0.25", "0.5", "1", "1.5", "2"])
        XCTAssertEqual(RacketPlayerText.zoom(2.43), "2.4×")
        XCTAssertEqual(RacketPlayerText.skip(10), "+10 s")
        XCTAssertEqual(RacketPlayerText.skip(-20), "−20 s")
        XCTAssertEqual(RacketPlayerText.downloading(0.42), "Downloading from iCloud · 42%")
        XCTAssertEqual(RacketPlayerText.title("Game 1 video"), "Game 1")
        XCTAssertEqual(RacketPlayerText.title("Block 2"), "Block 2")
        XCTAssertEqual(RacketPlayerText.holdLabel, "2× · release for normal speed")
        XCTAssertEqual(RacketPlayerText.turnHint, "Turn the phone for full screen")
    }

    // MARK: Rallies

    func testRalliesAreSortedAndRunningScoreIncludesTheCurrentRally() {
        let rs = four
        XCTAssertEqual(rs.rallies.map(\.startSec), [10, 30, 50, 80])
        XCTAssertEqual(rs.index(at: 12), 0)
        XCTAssertNil(rs.index(at: 20))
        XCTAssertEqual(rs.lastStarted(at: 20), 0)
        XCTAssertNil(rs.lastStarted(at: 5))
        XCTAssertTrue(rs.runningScore(at: 5)! == (0, 0))
        XCTAssertTrue(rs.runningScore(at: 31)! == (1, 1))
        XCTAssertTrue(rs.runningScore(at: 81)! == (2, 1), "untagged rally 3 counts for nobody")
        XCTAssertNil(RacketPlayerRallies([rally(1, 5)]).runningScore(at: 3), "nothing tagged: no pill")
    }

    func testPreviousRestartsTheRallyThenGoesBackAndNextGoesForward() {
        let rs = four
        XCTAssertEqual(rs.previousStart(from: 33), 30, "2 s into rally 2: its start")
        XCTAssertEqual(rs.previousStart(from: 30.5), 10, "at its start: the rally before")
        XCTAssertEqual(rs.previousStart(from: 40), 30, "between rallies: the last one")
        XCTAssertNil(rs.previousStart(from: 10.2))
        XCTAssertNil(rs.previousStart(from: 3))
        XCTAssertEqual(rs.nextStart(from: 12), 30)
        XCTAssertEqual(rs.nextStart(from: 0), 10)
        XCTAssertNil(rs.nextStart(from: 81))
        XCTAssertEqual(rs.nextStart(from: 29.99), 50, "a rally starting under the playhead is not next")
    }

    func testLoopTargetIsThePlayingRallyElseTheNextElseTheLast() {
        let rs = four
        XCTAssertEqual(rs.loopTarget(at: 31)?.number, 2)
        XCTAssertEqual(rs.loopTarget(at: 31)?.range, 30...35)
        XCTAssertEqual(rs.loopTarget(at: 40)?.number, 3)
        XCTAssertEqual(rs.loopTarget(at: 200)?.number, 4)
        XCTAssertNil(RacketPlayerRallies([]).loopTarget(at: 1))
    }

    func testTopBarAndLabelLines() {
        let rs = four
        XCTAssertEqual(RacketPlayerCopy.subtitle(rs, at: 81), "2 – 1 · Rally 4 of 4")
        XCTAssertEqual(RacketPlayerCopy.subtitle(rs, at: 2), "0 – 0 · 4 rallies")
        XCTAssertEqual(RacketPlayerCopy.subtitle(RacketPlayerRallies([rally(1, 5)]), at: 2), "Rally 1 of 1", "no tags: no score")
        XCTAssertEqual(RacketPlayerCopy.subtitle(RacketPlayerRallies([]), at: 2), "No score yet")
        XCTAssertEqual(RacketPlayerCopy.subtitle(RacketPlayerRallies([]), at: 2, loggedScore: "9–11"), "9–11")
        XCTAssertEqual(RacketPlayerCopy.subtitle(rs, at: 2, missing: true), "Video missing")
        XCTAssertEqual(RacketPlayerCopy.landscapeTitle("Game 1", rs, at: 81), "Game 1 · 2 – 1 · Rally 4 of 4")

        XCTAssertEqual(RacketPlayerCopy.rallyLine(rs, at: 12, sides: sides), "Rally 1 · You won · 6.0 s")
        XCTAssertEqual(RacketPlayerCopy.rallyLine(rs, at: 31, sides: sides), "Rally 2 · Alex won · 5.0 s")
        XCTAssertEqual(RacketPlayerCopy.rallyLine(rs, at: 51, sides: sides), "Rally 3 · untagged · 8.0 s")
        XCTAssertEqual(RacketPlayerCopy.rallyLine(rs, at: 20, sides: sides), "Between rallies")
        XCTAssertEqual(RacketPlayerCopy.rallyLine(RacketPlayerRallies([]), at: 20, sides: sides), "No rallies marked yet")

        XCTAssertEqual(RacketPlayerCopy.scrubLine(rs, at: 51, sides: sides)?.text, "Rally 3 · untagged")
        XCTAssertEqual(RacketPlayerCopy.scrubLine(rs, at: 51, sides: sides)?.untagged, true)
        XCTAssertEqual(RacketPlayerCopy.scrubLine(rs, at: 12, sides: sides)?.text, "Rally 1 · You won")
        XCTAssertNil(RacketPlayerCopy.scrubLine(rs, at: 20, sides: sides))
        XCTAssertEqual(RacketPlayerCopy.compactRally(rs, at: 12), "Rally 1 · 6.0 s")
    }

    func testEndLineUsesTheLoggedScore() {
        XCTAssertEqual(RacketPlayerCopy.endLine("Game 1", score: RacketUnitScore(scoreFor: 11, scoreAgainst: 9)),
                       "Game 1 ended · Won 11–9")
        XCTAssertEqual(RacketPlayerCopy.endLine("Game 2", score: RacketUnitScore(scoreFor: 9, scoreAgainst: 11)),
                       "Game 2 ended · Lost 9–11")
        XCTAssertEqual(RacketPlayerCopy.endLine("Block 1", score: nil), "Block 1 ended")
        XCTAssertEqual(RacketPlayerCopy.endLine("Game 3", score: RacketUnitScore(scoreFor: 5, scoreAgainst: 5)), "Game 3 ended")
    }

    func testModeBadges() {
        XCTAssertEqual(RacketPlayerCopy.modeBadges(loopNumber: 12, ralliesOnly: false, rate: 0.5), ["Loop · rally 12", "0.5×"])
        XCTAssertEqual(RacketPlayerCopy.modeBadges(loopNumber: nil, ralliesOnly: true, rate: 1), ["Rallies only"])
        XCTAssertEqual(RacketPlayerCopy.modeBadges(loopNumber: 3, ralliesOnly: true, rate: 1), ["Loop · rally 3"], "a loop wins over rallies only")
        XCTAssertEqual(RacketPlayerCopy.modeBadges(loopNumber: nil, ralliesOnly: false, rate: 1), [])
    }

    // MARK: Controls

    func testControlsHideOnlyWhilePlayingAfterThreeIdleSeconds() {
        XCTAssertTrue(RacketPlayerChrome.shouldHide(visible: true, playing: true, idleSec: 3, dragging: false, menuOpen: false))
        XCTAssertFalse(RacketPlayerChrome.shouldHide(visible: true, playing: false, idleSec: 30, dragging: false, menuOpen: false), "paused: they stay")
        XCTAssertFalse(RacketPlayerChrome.shouldHide(visible: true, playing: true, idleSec: 2.9, dragging: false, menuOpen: false))
        XCTAssertFalse(RacketPlayerChrome.shouldHide(visible: true, playing: true, idleSec: 9, dragging: true, menuOpen: false))
        XCTAssertFalse(RacketPlayerChrome.shouldHide(visible: true, playing: true, idleSec: 9, dragging: false, menuOpen: true))
        XCTAssertFalse(RacketPlayerChrome.shouldHide(visible: false, playing: true, idleSec: 9, dragging: false, menuOpen: false))
    }

    func testSingleTapTogglesAtOnce() {
        var taps = RacketPlayerTaps()
        XCTAssertEqual(taps.tap(x: 100, width: 400, at: 1.0), [.toggleControls])
        XCTAssertEqual(taps.tap(x: 100, width: 400, at: 2.0), [.toggleControls], "a second tap after the window is its own tap")
    }

    func testDoubleTapUndoesTheToggleAndSkipsOnThatSide() {
        var taps = RacketPlayerTaps()
        _ = taps.tap(x: 300, width: 400, at: 1.0)
        XCTAssertEqual(taps.tap(x: 310, width: 400, at: 1.2), [.toggleControls, .skip(10), .ripple(.forward, total: 10)])
        // A third tap on the same side keeps skipping (+20 s), without touching the controls.
        XCTAssertEqual(taps.tap(x: 320, width: 400, at: 1.6), [.skip(10), .ripple(.forward, total: 20)])
        XCTAssertEqual(taps.tap(x: 320, width: 400, at: 2.0), [.skip(10), .ripple(.forward, total: 30)])
        // Long after: a plain tap again.
        XCTAssertEqual(taps.tap(x: 320, width: 400, at: 5.0), [.toggleControls])

        var back = RacketPlayerTaps()
        _ = back.tap(x: 50, width: 400, at: 1.0)
        XCTAssertEqual(back.tap(x: 60, width: 400, at: 1.25), [.toggleControls, .skip(-10), .ripple(.back, total: -10)])
        // The other side during a streak ends it: that tap toggles.
        XCTAssertEqual(back.tap(x: 350, width: 400, at: 1.5), [.toggleControls])
    }

    func testHoldPlaysAtTwiceAndRestores() {
        var h = RacketPlayerHold()
        let b = h.begin(rate: 0.5, playing: false)
        XCTAssertEqual(b.rate, 2)
        XCTAssertTrue(b.play)
        XCTAssertTrue(h.isHolding)
        _ = h.begin(rate: 2, playing: true)   // a repeated begin keeps the first saved speed
        let e = h.end()
        XCTAssertEqual(e?.rate, 0.5)
        XCTAssertEqual(e?.pause, true, "it was paused before the hold")
        XCTAssertNil(h.end())
        var p = RacketPlayerHold()
        _ = p.begin(rate: 1, playing: true)
        XCTAssertEqual(p.end()?.pause, false)
    }

    func testLoopJumpsBackJustPastTheEndAndEndsWhenMovedAway() {
        XCTAssertNil(RacketPlayerLoop.jump(at: 32, loop: 30...35))
        XCTAssertEqual(RacketPlayerLoop.jump(at: 35.05, loop: 30...35), .to(30))
        XCTAssertEqual(RacketPlayerLoop.jump(at: 50, loop: 30...35), .clear)
        XCTAssertEqual(RacketPlayerLoop.jump(at: 10, loop: 30...35), .clear)
    }

    // MARK: Zoom and fit

    func testZoomClampsScaleAndPan() {
        XCTAssertEqual(RacketPlayerZoom.clamp(0.4), 1)
        XCTAssertEqual(RacketPlayerZoom.clamp(9), 5)
        XCTAssertFalse(RacketPlayerZoom.isZoomed(1))
        XCTAssertTrue(RacketPlayerZoom.isZoomed(2.4))
        let view = CGSize(width: 390, height: 844)
        // A full-screen video at 2×: can move half the extra each way.
        let o = RacketPlayerZoom.clampOffset(CGSize(width: 900, height: -900), scale: 2, video: view, view: view)
        XCTAssertEqual(o.width, 195, accuracy: 0.01)
        XCTAssertEqual(o.height, -422, accuracy: 0.01)
        // A letterboxed sideways video at 1.5×: still shorter than the screen, so it stays centred vertically.
        let lb = RacketPlayerZoom.clampOffset(CGSize(width: 10, height: 50), scale: 1.5,
                                              video: CGSize(width: 390, height: 219), view: view)
        XCTAssertEqual(lb.height, 0)
        XCTAssertEqual(lb.width, 10)
    }

    func testFitAndTheTurnHint() {
        let r = RacketPlayerFit.fitted(video: CGSize(width: 1920, height: 1080), in: CGSize(width: 390, height: 844))
        XCTAssertEqual(r.width, 390, accuracy: 0.01)
        XCTAssertEqual(r.height, 219.375, accuracy: 0.01)
        XCTAssertEqual(r.midY, 422, accuracy: 0.01)
        XCTAssertTrue(RacketPlayerFit.showsTurnHint(video: CGSize(width: 1920, height: 1080), view: CGSize(width: 390, height: 844)))
        XCTAssertFalse(RacketPlayerFit.showsTurnHint(video: CGSize(width: 1080, height: 1920), view: CGSize(width: 390, height: 844)))
        XCTAssertFalse(RacketPlayerFit.showsTurnHint(video: CGSize(width: 1920, height: 1080), view: CGSize(width: 844, height: 390)),
                       "already turned")
        XCTAssertFalse(RacketPlayerFit.showsTurnHint(video: nil, view: CGSize(width: 390, height: 844)))
    }

    // MARK: Filmstrip

    func testStripShowsAboutAMinuteAndMapsOffsetToTime() {
        let s = RacketFilmstrip(start: 100, end: 400, visibleWidth: 240)
        XCTAssertEqual(s.pointsPerSec, 4, accuracy: 0.001, "240 pt show 60 s")
        XCTAssertEqual(s.length, 1200, accuracy: 0.001)
        XCTAssertEqual(s.x(at: 130), 120, accuracy: 0.001)
        XCTAssertEqual(s.offset(at: 130), -120, accuracy: 0.001)
        // Dragging the strip left moves forward in time; right moves back; clamped to the part.
        XCTAssertEqual(s.time(dragging: -40, from: 130), 140, accuracy: 0.001)
        XCTAssertEqual(s.time(dragging: 40, from: 130), 120, accuracy: 0.001)
        XCTAssertEqual(s.time(dragging: 4000, from: 130), 100)
        XCTAssertEqual(s.time(dragging: -4000, from: 130), 400)
        // A short part fills the strip.
        let short = RacketFilmstrip(start: 0, end: 30, visibleWidth: 240)
        XCTAssertEqual(short.pointsPerSec, 8, accuracy: 0.001)
    }

    func testStripTilesAndSharedThumbnails() {
        let s = RacketFilmstrip(start: 0, end: 60, visibleWidth: 240)
        let times = s.tileTimes(tileWidth: 30)
        XCTAssertEqual(times.count, 8)
        XCTAssertEqual(times.first!, 3.75, accuracy: 0.001)
        XCTAssertEqual(RacketFilmstrip.thumbnailIndex(tile: 0, tiles: 120, count: 60), 0)
        XCTAssertEqual(RacketFilmstrip.thumbnailIndex(tile: 119, tiles: 120, count: 60), 59)
        XCTAssertEqual(RacketFilmstrip.thumbnailIndex(tile: 61, tiles: 120, count: 60), 30)
        XCTAssertEqual(RacketFilmstrip.thumbnailIndex(tile: 5, tiles: 8, count: 0), 0)
    }

    func testDragSeeksExactFramesWhenSlow() {
        XCTAssertEqual(RacketFilmstrip.dragTolerance(videoSecPerSec: 0), 0)
        XCTAssertEqual(RacketFilmstrip.dragTolerance(videoSecPerSec: -3), 0, "slow either way: exact frames")
        XCTAssertEqual(RacketFilmstrip.dragTolerance(videoSecPerSec: 10), 0.5, accuracy: 0.001)
        XCTAssertEqual(RacketFilmstrip.dragTolerance(videoSecPerSec: 100), 1)
    }

    func testBandsAreWonLostOrUntaggedAsFractions() {
        XCTAssertEqual(RacketPlayerBand.of(rally(0, 1, .us)), .won)
        XCTAssertEqual(RacketPlayerBand.of(rally(0, 1, .them)), .lost)
        XCTAssertEqual(RacketPlayerBand.of(rally(0, 1)), .untagged)
        let f = RacketPlayerBand.fractions(four, start: 0, end: 100)
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(f[0].from, 0.10, accuracy: 0.0001)
        XCTAssertEqual(f[0].to, 0.16, accuracy: 0.0001)
        XCTAssertEqual(f[2].band, .untagged)
        XCTAssertEqual(RacketPlayerBand.fractions(four, start: 0, end: 20).count, 1, "rallies outside the part are dropped")
    }

    // MARK: Seed

    func testPlayerSeedMatchesTheBoards() {
        let log = RacketVideoSeed.playerLog(startedAt: .now, variant: "portrait")
        let rs = RacketPlayerRallies(RacketRallyMarking.inRange(log.allRallies, 0, 300))
        XCTAssertEqual(rs.count, 21)
        let twelve = rs.rallies[11]
        XCTAssertEqual(RacketPlayerCopy.subtitle(rs, at: twelve.startSec + 1), "7 – 5 · Rally 12 of 21")
        XCTAssertEqual(RacketPlayerCopy.scrubLine(rs, at: rs.rallies[12].startSec + 1, sides: sides)?.text, "Rally 13 · untagged")
        XCTAssertEqual(RacketPlayerCopy.rallyLine(rs, at: twelve.startSec + 1, sides: sides), "Rally 12 · You won · 6.2 s")
        XCTAssertEqual(RacketPlayerCopy.subtitle(rs, at: 299), "11 – 9 · Rally 21 of 21")
        XCTAssertTrue(RacketRallyMarking.inRange(log.allRallies, 330, 390).isEmpty, "game 2 has none")
        XCTAssertEqual(log.split?.countedParts.count, 2)
    }
}
