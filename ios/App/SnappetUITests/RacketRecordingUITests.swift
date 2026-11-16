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
        XCTAssertTrue(any("racket.rec.preview").exists, "the camera step shows the preview for framing")
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

    func testMatchRecordsEverythingThenStopsToTheSplitPrompt() {
        openRacketSetup()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
        let opponent = app.textFields["racket.opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Alex\n")
        tapWhenHittable(app.buttons["racket.recording.everything"])
        XCTAssertEqual(app.buttons["racket.recording.everything"].label, "Everything, split later")
        // Match → Camera → Warmup → Storage (prompt 249: the boards' "Set up camera" path).
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])
        let toWarmup = app.buttons["racket.camera.continue"]
        XCTAssertTrue(toWarmup.waitForExistence(timeout: 8), "Set up camera opens the camera check")
        toWarmup.tap()
        XCTAssertTrue(app.buttons["racket.warmup.mode.everything"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.warmup.mode.everything"].isSelected, "warmup keeps the match's choice")
        app.buttons["racket.warmup.start"].tap()
        XCTAssertTrue(app.buttons["racket.storage.continue"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["racket.storage.cancel"].label, "Back", "TtStorage: Back after setup")
        app.buttons["racket.storage.continue"].tap()

        // RecordAll: recording starts at once; marks count.
        let mark = app.buttons["racket.rec.mark"]
        XCTAssertTrue(mark.waitForExistence(timeout: 8), "the match should start recording now")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"))
        // Device feedback round 1: it opens on the camera (a stand-in here); Dim · Camera · Stats switch it.
        XCTAssertTrue(any("racket.rec.preview").exists, "the camera view shows while recording")
        XCTAssertTrue(app.buttons["racket.rec.show.camera"].isSelected)
        XCTAssertEqual(any("racket.rec.scoreCaption").label, "Games", "no Watch points yet: the match so far")
        app.buttons["racket.rec.show.stats"].tap()
        XCTAssertFalse(any("racket.rec.preview").exists, "Stats has no camera")
        XCTAssertTrue(any("racket.rec.stats.sessionTime").waitForExistence(timeout: 3), "LiveStatsOff: session time")
        XCTAssertEqual(any("racket.rec.stats.source").label, "From your tags, 0 of 0")
        app.buttons["racket.rec.show.dim"].tap()
        XCTAssertFalse(any("racket.rec.preview").exists, "Dim is TtRecordAll on black, still recording")
        XCTAssertTrue(app.buttons["racket.rec.mark"].exists, "Dim keeps Mark this moment")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"))
        app.buttons["racket.rec.show.camera"].tap()
        XCTAssertTrue(any("racket.rec.preview").waitForExistence(timeout: 3))
        mark.tap()
        app.buttons["racket.rec.newGame"].tap()

        // Stop and split → the split prompt straight away (V2.6: no extra confirm, as on the board).
        app.buttons["racket.rec.stop"].tap()
        XCTAssertTrue(any("racket.split.recorded").waitForExistence(timeout: 6), "the split prompt should show")
        // One "New game starts" ⇒ two games proposed.
        XCTAssertTrue(any("racket.split.line").label.hasPrefix("Looks like 2 games"), any("racket.split.line").label)

        // Later: both games are logged "Score unconfirmed" (step 1's one state), and Your videos opens.
        app.buttons["racket.split.later"].tap()
        let whole = any("racket.videos.line.0")
        XCTAssertTrue(whole.waitForExistence(timeout: 5), "Your videos should open")
        XCTAssertTrue(whole.label.hasSuffix("not split yet"), whole.label)
        app.buttons["racket.videos.close"].tap()

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
