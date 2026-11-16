import XCTest
import CoreGraphics
@testable import Snappet

/// Unit tests for the **rally video's controls** (prompt 257): the turn maths (`RacketVideoTurn`: fold, next, stored,
/// swapped size, aspect), the box shape (full width, capped height, placeholder), the tag sheet's cap, the loop stretch
/// ("−3 s" / "+3 s" clamped to the part, scrub fraction ↔ time, the rally's band, the time line, restart), the speed
/// cycle, the tap toggle, and the recording's turn surviving a round trip (old data loads without it). No device.
final class RacketRallyVideoControlsTests: XCTestCase {

    // MARK: Turns

    func testTurnsFoldIntoZeroToThree() {
        XCTAssertEqual(RacketVideoTurn.normalized(nil), 0)
        XCTAssertEqual(RacketVideoTurn.normalized(5), 1)
        XCTAssertEqual(RacketVideoTurn.normalized(-1), 3)
        XCTAssertEqual(RacketVideoTurn.next(nil), 1)
        XCTAssertEqual(RacketVideoTurn.next(3), 0)
        XCTAssertNil(RacketVideoTurn.stored(4), "upright is stored as nil, so untouched data stays as it was")
        XCTAssertEqual(RacketVideoTurn.stored(2), 2)
        XCTAssertEqual(RacketVideoTurn.degrees(3), 270)
    }

    func testAQuarterTurnSwapsTheSides() {
        let portrait = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(RacketVideoTurn.displayed(portrait, turns: 1), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(RacketVideoTurn.displayed(portrait, turns: 2), portrait)
        XCTAssertEqual(RacketVideoTurn.aspect(portrait, turns: 0)!, 1080.0 / 1920.0, accuracy: 0.0001)
        XCTAssertEqual(RacketVideoTurn.aspect(portrait, turns: 3)!, 1920.0 / 1080.0, accuracy: 0.0001)
        XCTAssertNil(RacketVideoTurn.aspect(nil, turns: 1))
        XCTAssertNil(RacketVideoTurn.aspect(.zero, turns: 0))
    }

    // MARK: The box

    func testLandscapeFillsTheWidthAtSixteenByNine() {
        let b = RacketVideoTurn.box(aspect: 16.0 / 9.0, width: 361, maxHeight: 480)
        XCTAssertEqual(b.width, 361)
        XCTAssertEqual(b.height, 361 * 9 / 16, accuracy: 0.01)
    }

    func testPortraitIsCappedAndNarrowsWithNoSideBars() {
        let a: CGFloat = 9.0 / 16.0
        let b = RacketVideoTurn.box(aspect: a, width: 361, maxHeight: 480)
        XCTAssertEqual(b.height, 480)
        XCTAssertEqual(b.width, 480 * a, accuracy: 0.01)
        XCTAssertEqual(b.width / b.height, a, accuracy: 0.0001, "the box is the picture's shape")
    }

    func testUnknownShapeUsesThePlaceholder() {
        let b = RacketVideoTurn.box(aspect: nil, width: 320, maxHeight: 400)
        XCTAssertEqual(b.height, 180, accuracy: 0.01)
        XCTAssertEqual(RacketVideoTurn.box(aspect: 1, width: 0, maxHeight: 400), .zero)
    }

    func testTagSheetCapKeepsTheWinnerRowOnTheFirstScreen() {
        // A 6.1" phone's sheet: about 730 pt visible under the bar.
        let cap = RacketVideoTurn.tagSheetCap(visibleHeight: 730)
        XCTAssertLessThanOrEqual(cap, 730 - 250)
        XCTAssertGreaterThan(cap, 400, "still a big picture")
        XCTAssertEqual(RacketVideoTurn.tagSheetCap(visibleHeight: 0), 300, "before the sheet is measured")
        XCTAssertEqual(RacketVideoTurn.tagSheetCap(visibleHeight: 300), 180, "never tiny")
    }

    // MARK: The loop

    func testLoopPadsTheRallyASecondEachSide() {
        let l = RacketRallyLoop(rally: 20...28, partStart: 0, partEnd: 100)
        XCTAssertEqual(l.window, 19...29)
        XCTAssertEqual(l.length, 10)
    }

    func testWideningAddsThreeSecondsAndStopsAtThePartsEdges() {
        var l = RacketRallyLoop(rally: 6...10, partStart: 0, partEnd: 15)
        l.widenEarlier()
        XCTAssertEqual(l.window.lowerBound, 2)
        XCTAssertTrue(l.canWidenEarlier)
        l.widenEarlier()
        XCTAssertEqual(l.window.lowerBound, 0, "clamped to the part")
        XCTAssertFalse(l.canWidenEarlier)
        l.widenEarlier()
        XCTAssertEqual(l.window.lowerBound, 0)
        l.widenLater()
        XCTAssertEqual(l.window.upperBound, 14)
        l.widenLater()
        XCTAssertEqual(l.window.upperBound, 15)
        XCTAssertFalse(l.canWidenLater)
    }

    func testRallyAtThePartsStartCannotWidenEarlier() {
        let l = RacketRallyLoop(rally: 0.5...4, partStart: 0, partEnd: 60)
        XCTAssertEqual(l.window.lowerBound, 0)
        XCTAssertFalse(l.canWidenEarlier)
    }

    func testScrubFractionsMapToTimesAndBack() {
        let l = RacketRallyLoop(rally: 20...28, partStart: 0, partEnd: 100)
        XCTAssertEqual(l.time(atFraction: 0.5), 24)
        XCTAssertEqual(l.time(atFraction: -1), 19)
        XCTAssertEqual(l.time(atFraction: 2), 29)
        XCTAssertEqual(l.fraction(of: 24), 0.5)
        XCTAssertEqual(l.fraction(of: 50), 1)
        XCTAssertEqual(l.rallyFractions.from, 0.1, accuracy: 0.0001)
        XCTAssertEqual(l.rallyFractions.to, 0.9, accuracy: 0.0001)
    }

    func testTimeLineIsTheLoopsOwnClock() {
        let l = RacketRallyLoop(rally: 20...28, partStart: 0, partEnd: 100)
        XCTAssertEqual(l.timeLine(22.4), "0:03 / 0:10")
        XCTAssertEqual(l.timeLine(5), "0:00 / 0:10")
    }

    func testRestartsAtTheEndOrOutsideButNotWhilePlaying() {
        let l = RacketRallyLoop(rally: 20...28, partStart: 0, partEnd: 100)
        XCTAssertTrue(l.shouldRestart(position: 28.9, playing: false))
        XCTAssertTrue(l.shouldRestart(position: 10, playing: false))
        XCTAssertFalse(l.shouldRestart(position: 24, playing: false), "paused mid-loop by a stop elsewhere stays")
        XCTAssertFalse(l.shouldRestart(position: 28.9, playing: true))
    }

    // MARK: Speed and tap

    func testSpeedCyclesOneHalfQuarter() {
        XCTAssertEqual(RacketRallyVideoSpeed.next(1), 0.5)
        XCTAssertEqual(RacketRallyVideoSpeed.next(0.5), 0.25)
        XCTAssertEqual(RacketRallyVideoSpeed.next(0.25), 1)
        XCTAssertEqual(RacketRallyVideoSpeed.next(2), 1, "an unknown speed goes back to 1×")
        XCTAssertEqual(RacketPlayerText.speed(0.25), "0.25×")
    }

    func testTapTogglesWithItsGlyph() {
        XCTAssertEqual(RacketRallyVideoTap.toggle(playing: true).play, false)
        XCTAssertEqual(RacketRallyVideoTap.toggle(playing: true).glyph, "pause.fill")
        XCTAssertEqual(RacketRallyVideoTap.toggle(playing: false).play, true)
        XCTAssertEqual(RacketRallyVideoTap.toggle(playing: false).glyph, "play.fill")
    }

    // MARK: Stored on the recording

    func testTurnRoundTripsAndOldLogsLoadWithout() throws {
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        log.quarterTurns = RacketVideoTurn.stored(RacketVideoTurn.next(nil))
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(RacketRecordingLog.self, from: data).quarterTurns, 1)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["quarterTurns"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(RacketRecordingLog.self, from: old).quarterTurns)
    }
}
