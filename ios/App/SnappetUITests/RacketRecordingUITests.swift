import XCTest

/// UI coverage for **racket recording** (prompt 244, issue #438 step 1): the recording mode chosen in setup, the
/// storage check, and record everything for a drill (camera → countdown → block → rest → review) and for a match
/// (RecordAll → Stop and split → the saved placeholder). The simulator has no camera: `-uiTestFakeCamera` runs the
/// recorder as a stand-in, so the screens and the state machine run end to end without a device.
final class RacketRecordingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera"]
        app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Forms are lazy: a row below the fold isn't in the hierarchy until it's scrolled to.
    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 5 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openRacketSetup() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        let tt = app.buttons["racket.sport.tableTennis"]
        XCTAssertTrue(tt.waitForExistence(timeout: 5), "the sport picker should open")
        tt.tap()
    }

    private func confirmStop() {
        let confirm = app.buttons.matching(identifier: "racket.rec.confirmStop").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "stopping is confirmed first")
        confirm.tap()
    }

    func testDrillRecordsEverythingWithBlocksAndRestsMarked() {
        openRacketSetup()
        app.segmentedControls["racket.mode"].buttons["Drill"].tap()
        app.buttons["racket.next"].tap()
        let drill = app.buttons["racket.drill"].firstMatch
        XCTAssertTrue(drill.waitForExistence(timeout: 5))
        drill.tap()

        // Plan + recording (M1: no "split later" for a drill).
        let everything = app.buttons["racket.recording.everything"]
        XCTAssertTrue(everything.waitForExistence(timeout: 5), "the drill plan step should show")
        XCTAssertEqual(everything.label, "Everything, rests included")
        everything.tap()
        // PracticeSetup: one tap, labelled by what comes next.
        let start = app.buttons["racket.plan.start"]
        tapWhenHittable(start)

        // Setup → Storage (the boards' flow): the storage check opens by itself.
        let room = any("racket.storage.room")
        XCTAssertTrue(room.waitForExistence(timeout: 5), "the storage check should open")
        XCTAssertTrue(room.label.hasPrefix("Room for about"), room.label)
        app.buttons["racket.storage.continue"].tap()

        // Camera first, then block 1 (M3: Wait before block 1 goes back here, never to a rest timer).
        let startBlock = app.buttons["racket.rec.startBlock"]
        XCTAssertTrue(startBlock.waitForExistence(timeout: 8), "the recording screen should open on the camera")
        startBlock.tap()
        XCTAssertTrue(any("racket.rec.countdown").waitForExistence(timeout: 4), "a countdown to block 1")
        app.buttons["racket.rec.wait"].tap()
        XCTAssertTrue(startBlock.waitForExistence(timeout: 4), "Wait goes back to the camera")
        startBlock.tap()

        // The block records; End block → rest (recording continues).
        let endBlock = app.buttons["racket.rec.endBlock"]
        XCTAssertTrue(endBlock.waitForExistence(timeout: 12), "block 1 should start after the countdown")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"), any("racket.rec.status").label)
        endBlock.tap()
        XCTAssertTrue(app.buttons["racket.rec.pauseRest"].waitForExistence(timeout: 4), "the rest timer should run")
        XCTAssertEqual(any("racket.rec.phase").label, "Rest")

        // Finish drill → review: one recording, its block parts.
        app.buttons["racket.rec.stop"].tap()
        confirmStop()
        let summary = any("racket.rec.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "the drill review should show")
        XCTAssertEqual(summary.label, "1 recording · 1 block part")
        app.buttons["racket.rec.done"].tap()

        // Back on the drill page: the block is logged and the recording line describes it.
        XCTAssertTrue(any("racket.recording.line").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.recording.line").label, "1 recording · 1 block part")
    }

    func testMatchRecordsEverythingThenStopsToTheSplitPlaceholder() {
        openRacketSetup()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
        let opponent = app.textFields["racket.opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Alex\n")
        tapWhenHittable(app.buttons["racket.recording.everything"])
        XCTAssertEqual(app.buttons["racket.recording.everything"].label, "Everything, split later")
        tapWhenHittable(app.buttons["racket.startMatch"])

        // Everything → Storage straight from setup.
        XCTAssertTrue(app.buttons["racket.storage.continue"].waitForExistence(timeout: 6))
        app.buttons["racket.storage.continue"].tap()

        // RecordAll: recording starts at once; marks count.
        let mark = app.buttons["racket.rec.mark"]
        XCTAssertTrue(mark.waitForExistence(timeout: 8), "the match should start recording now")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"))
        mark.tap()
        app.buttons["racket.rec.newGame"].tap()

        // Stop and split → the saved placeholder (H1: a whole-match recording ends at the split prompt).
        app.buttons["racket.rec.stop"].tap()
        confirmStop()
        XCTAssertTrue(any("racket.rec.recorded").waitForExistence(timeout: 5), "the recording-saved screen should show")

        // Then the game scores: one "New game starts" ⇒ two games. Game 1 later, game 2 left for Done.
        let later = app.buttons["racket.scores.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 4), "the scores step should ask for game 1")
        XCTAssertTrue(app.buttons["racket.scores.enter"].exists)
        later.tap()
        XCTAssertEqual(any("racket.scores.state.0").label, "Score unconfirmed")
        XCTAssertTrue(app.buttons["racket.scores.later"].waitForExistence(timeout: 3), "then game 2")
        app.buttons["racket.rec.done"].tap()

        // Back on the match page: both games read "Score unconfirmed" and can be confirmed from their chips.
        let line = any("racket.recording.line")
        XCTAssertTrue(line.waitForExistence(timeout: 6))
        XCTAssertTrue(line.label.hasSuffix("2 marks"), line.label)
        let pending = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Score unconfirmed'"))
        XCTAssertEqual(pending.count, 2, "two unconfirmed game chips")
        pending.firstMatch.tap()
        XCTAssertTrue(app.buttons["racket.score.save"].waitForExistence(timeout: 5), "an unconfirmed game opens its score sheet")
        app.buttons["racket.score.save"].tap()
        XCTAssertTrue(app.buttons["racket.score.save"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Score unconfirmed'")).count, 1,
                       "confirming one leaves the other")
    }
}
