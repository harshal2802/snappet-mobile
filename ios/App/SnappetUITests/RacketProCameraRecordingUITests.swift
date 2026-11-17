import XCTest

/// UI coverage for the **racket pro camera while recording** (prompt 256, issue #448 part 2; boards ProCameraRecording →
/// ProCameraLandscape): the recording chrome (game and score, red timer, locked quality, lenses, DIM / CAMERA / STATS,
/// Tag, stop, Mark), one-tap stop → the score sheet → "That was a mistake, keep playing", the break on the camera,
/// record everything with "New game starts", a drill block, warm / too hot / interrupted / low space, and sideways.
///
/// The fake camera (`-uiTestFakeCamera`) is forced into each state: `-uiTestCameraTrouble` adds tiny DEBUG buttons for
/// heat and a call, `-uiTestCameraFreeGB` / `-uiTestCameraBattery` / `-uiTestWatchOff` set the rest, and `-uiTestWatchTaps`
/// stands in for the Watch's score taps. `RACKET_SHOTS=<dir>` writes the board screenshots. Simulator only (it records).
final class RacketProCameraRecordingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(freeGB: String = "45", battery: String = "82", _ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera", "-uiTestWatchReady", "-uiTestWatchTaps",
                                "-uiTestCameraTrouble", "-uiTestCameraLenses", "0.5,1,2,3",
                                "-uiTestCameraFreeGB", freeGB, "-uiTestCameraBattery", battery]
        app.launchArguments += extra
        app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
        app.launchOnTestStore()
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["RACKET_SHOTS"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 5 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openRacket() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        let tt = app.buttons["racket.sport.tableTennis"]
        XCTAssertTrue(tt.waitForExistence(timeout: 5))
        tt.tap()
    }

    /// Match form → the pro camera (Alex serves first).
    private func openCamera(everything: Bool = false, setServer: Bool = true) {
        openRacket()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
        let field = app.textFields["racket.opponent"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Alex\n")
        if everything { tapWhenHittable(app.buttons["racket.recording.everything"]) }
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])
        XCTAssertTrue(app.buttons["racket.camera.shutter"].waitForExistence(timeout: 10))
        guard setServer else { return }
        app.buttons["racket.camera.options"].tap()
        XCTAssertTrue(app.buttons["racket.camera.serve.them"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.serve.them"].tap()
        app.buttons["racket.camera.optionsDone"].tap()
        sleep(1)
    }

    private func chooseQuality(_ key: String) {
        app.buttons["racket.camera.quality"].tap()
        XCTAssertTrue(app.buttons["racket.camera.quality.\(key)"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.quality.\(key)"].tap()
        app.buttons["racket.camera.qualityDone"].tap()
        sleep(1)
    }

    private func startGameByGame() {
        app.buttons["racket.camera.shutter"].tap()
        XCTAssertTrue(any("racket.game.status").waitForExistence(timeout: 8), "the recording chrome")
    }

    private func points(us: Int, them: Int) {
        for _ in 0..<us { app.buttons["racket.test.watchUs"].tap() }
        for _ in 0..<them { app.buttons["racket.test.watchThem"].tap() }
    }

    // MARK: - ProCameraRecording, ProCameraDim

    func testRecordingChromeViewsTagMarkAndFocus() {
        launch()
        openCamera()
        startGameByGame()
        let status = any("racket.game.status")
        XCTAssertTrue(status.label.hasPrefix("Recording"), status.label)
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 1 · 0 – 0")
        points(us: 4, them: 3)
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 1 · 4 – 3")
        XCTAssertFalse(app.buttons["racket.camera.quality"].isEnabled, "quality is locked while recording")
        for l in ["0.5", "1", "2", "3"] { XCTAssertTrue(app.buttons["racket.camera.lens.\(l)"].exists) }
        XCTAssertTrue(app.buttons["racket.rec.show.camera"].isSelected, "opens on CAMERA")
        XCTAssertEqual(app.buttons["racket.game.tagLast"].label, "Tag last rally")
        XCTAssertEqual(app.buttons["racket.game.mark"].label, "Mark this moment")
        XCTAssertEqual(app.buttons["racket.game.stop"].label, "Stop recording, end game 1")
        shot("ProCameraRecording")

        // Zoom and focus keep working while recording; a tap on the preview is always focus.
        app.buttons["racket.camera.lens.2"].tap()
        XCTAssertTrue(app.buttons["racket.camera.lens.2"].isSelected)
        any("racket.camera.preview").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(any("racket.camera.focus").waitForExistence(timeout: 3))
        any("racket.camera.preview").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.2)
        XCTAssertTrue(any("racket.camera.lockBadge").waitForExistence(timeout: 3), "AE/AF lock while recording")
        app.buttons["racket.camera.lens.1"].tap()

        // Mark, Tag (the existing live tag).
        app.buttons["racket.game.mark"].tap()
        app.buttons["racket.game.tagLast"].tap()
        XCTAssertTrue(any("racket.liveTag.title").waitForExistence(timeout: 3), "Tag opens the live tag")
        app.buttons["racket.liveTag.winner.us"].tap()
        app.buttons["racket.liveTag.done"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 4), "back on the camera")

        // DIM: the big score on black, the same controls.
        app.buttons["racket.rec.show.dim"].tap()
        XCTAssertEqual(any("racket.game.score").label, "4 – 3")
        // Alex served first; two serves each, so after 7 points it's you (the board's "Alex serving" at 4–3 is illustrative).
        XCTAssertEqual(any("racket.game.caption").label, "Game 1 · you’re serving")
        XCTAssertFalse(any("racket.camera.preview").exists, "Dim hides the picture")
        XCTAssertTrue(app.buttons["racket.game.mark"].exists)
        shot("ProCameraDim")
        app.buttons["racket.rec.show.stats"].tap()
        XCTAssertTrue(any("racket.rec.stats.source").waitForExistence(timeout: 3), "Stats")
        app.buttons["racket.rec.show.camera"].tap()
        XCTAssertTrue(any("racket.camera.preview").waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.hasPrefix("Recording"), "still recording through every view")
    }

    // MARK: - ProCameraStop, ProCameraBreak

    func testStopOpensTheScoreSheetAMistakeKeepsPlayingAndTheBreakIsOnTheCamera() {
        launch()
        openCamera()
        startGameByGame()
        points(us: 4, them: 3)
        app.buttons["racket.game.stop"].tap()
        let save = app.buttons["racket.save.startBreak"]
        XCTAssertTrue(save.waitForExistence(timeout: 4), "one tap on stop opens the score sheet")
        XCTAssertEqual(any("racket.save.title").label, "Game 1")
        XCTAssertEqual(any("racket.save.mine").label, "4")
        XCTAssertEqual(any("racket.save.theirs").label, "3")
        XCTAssertEqual(any("racket.save.subtitle").label, "From your Watch. Fix it now or later.")
        XCTAssertTrue(app.buttons["racket.save.matchOver"].exists)
        XCTAssertTrue(app.buttons["racket.save.laterBottom"].exists)
        XCTAssertEqual(app.buttons["racket.save.cancel"].label, "That was a mistake, keep playing game 1")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"), "the clip runs on under the sheet")
        shot("ProCameraStop")

        // The mistake: the same game, its score kept, still recording.
        app.buttons["racket.save.cancel"].tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 4))
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 1 · 4 – 3", "the score is kept")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"))
        points(us: 1, them: 0)
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 1 · 5 – 3", "the tally carries on")

        // Stop again → Save, start break → the break on the camera.
        app.buttons["racket.game.stop"].tap()
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        save.tap()
        let centre = any("racket.break.line")
        XCTAssertTrue(centre.waitForExistence(timeout: 5))
        XCTAssertTrue(centre.label.hasPrefix("Game 2 in "), centre.label)
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 1 saved · 5–3")
        XCTAssertEqual(any("racket.camera.notice").label, "Not recording. Lens and quality are unlocked.")
        XCTAssertTrue(app.buttons["racket.break.skip"].exists)
        XCTAssertTrue(app.buttons["racket.break.add30"].exists)
        XCTAssertTrue(app.buttons["racket.break.endMatch"].exists)
        XCTAssertTrue(app.buttons["racket.camera.videos"].exists)
        XCTAssertTrue(app.buttons["racket.camera.options"].exists)
        app.buttons["racket.camera.lens.0.5"].tap()
        XCTAssertTrue(app.buttons["racket.camera.lens.0.5"].isSelected)
        shot("ProCameraBreak")
        XCTAssertTrue(app.buttons["racket.camera.quality"].isEnabled, "quality is unlocked in the break")
        chooseQuality("uhd4k-30")
        XCTAssertEqual(app.buttons["racket.camera.quality"].label, "Video quality 4K · 30")
        // The break's own controls are in Options.
        app.buttons["racket.camera.options"].tap()
        XCTAssertTrue(app.buttons["racket.break.pause"].waitForExistence(timeout: 4))
        XCTAssertTrue(any("racket.break.autoStart").exists)
        app.buttons["racket.camera.optionsDone"].tap()
        sleep(1)
        // The shutter starts the next game early.
        app.buttons["racket.break.start"].tap()
        XCTAssertTrue(any("racket.camera.recTitle").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 2 · 0 – 0")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"))
        XCTAssertEqual(app.buttons["racket.camera.quality"].label, "Video quality 4K · 30")
        XCTAssertTrue(app.buttons["racket.camera.lens.0.5"].isSelected, "the lens chosen in the break carries")
    }

    // MARK: - ProCameraWarm, ProCameraHot

    func testWarmThenTooHotThenResumeWhenCoolAndKeepScoring() {
        launch()
        openCamera()
        chooseQuality("uhd4k-60")
        startGameByGame()
        points(us: 6, them: 8)
        app.buttons["racket.test.warm"].tap()
        let warm = any("racket.camera.warm")
        XCTAssertTrue(warm.waitForExistence(timeout: 3))
        XCTAssertEqual(warm.label, "▲ Warm at 4K · 60. Recording continues.")
        let next = app.buttons["racket.camera.nextFormat"]
        XCTAssertEqual(next.label, "HD · 30 from next game")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"), "recording continues")
        shot("ProCameraWarm")
        next.tap()
        XCTAssertEqual(next.label, "HD · 30 next game ✓")
        XCTAssertEqual(app.buttons["racket.camera.quality"].label, "Video quality 4K · 60", "never mid-file")
        app.buttons["racket.camera.warmDim"].tap()
        XCTAssertTrue(app.buttons["racket.rec.show.dim"].isSelected, "Dim")
        app.buttons["racket.rec.show.camera"].tap()

        // Too hot: recording stops safely.
        app.buttons["racket.test.hot"].tap()
        let title = any("racket.camera.stopTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "The phone got too hot to film")
        XCTAssertTrue(any("racket.camera.stopLine").label.hasPrefix("Everything up to "), any("racket.camera.stopLine").label)
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Stopped at "), any("racket.game.status").label)
        XCTAssertFalse(app.buttons["racket.camera.resumeCool"].isEnabled, "not until it cools")
        XCTAssertTrue(app.buttons["racket.int.keepScoring"].exists)
        shot("ProCameraHot")
        // Scoring from the Watch keeps working.
        points(us: 1, them: 0)
        XCTAssertEqual(any("racket.camera.recTitle").label, "Game 1 · 7 – 8")
        app.buttons["racket.test.cool"].tap()
        let resume = app.buttons["racket.camera.resumeCool"]
        XCTAssertTrue(resume.isEnabled, "cooled: Resume filming")
        resume.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 3))
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"), "a new part of the same game")

        // Too hot again → Keep scoring without video.
        app.buttons["racket.test.hot"].tap()
        XCTAssertTrue(app.buttons["racket.int.keepScoring"].waitForExistence(timeout: 3))
        app.buttons["racket.int.keepScoring"].tap()
        XCTAssertTrue(app.buttons["racket.scoreOnly.us"].waitForExistence(timeout: 4), "ScoreOnly carries the game")
        XCTAssertEqual(any("racket.game.score").label, "7 – 8")
    }

    // MARK: - ProCameraInterrupted

    func testACallPausesAndRecordingStartsAgainByItself() {
        launch()
        openCamera()
        startGameByGame()
        points(us: 4, them: 3)
        app.buttons["racket.test.call"].tap()
        let banner = any("racket.camera.interrupted")
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        XCTAssertEqual(banner.label, "Recording paused by a phone call")
        let line = any("racket.camera.interrupted.line")
        XCTAssertTrue(line.label.hasPrefix("Saved up to "), line.label)
        XCTAssertTrue(line.label.hasSuffix("It starts again by itself when the call ends."), line.label)
        XCTAssertTrue(app.buttons["racket.int.resume"].exists)
        XCTAssertEqual(app.buttons["racket.int.end"].label, "End game")
        shot("ProCameraInterrupted")
        app.buttons["racket.test.callEnded"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3), "the call ended: it starts again by itself")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"))
        app.buttons["racket.test.call"].tap()
        XCTAssertTrue(app.buttons["racket.int.resume"].waitForExistence(timeout: 3))
        app.buttons["racket.int.resume"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3), "Resume now")
        app.buttons["racket.test.call"].tap()
        XCTAssertTrue(app.buttons["racket.int.end"].waitForExistence(timeout: 3))
        app.buttons["racket.int.end"].tap()
        XCTAssertTrue(app.buttons["racket.save.startBreak"].waitForExistence(timeout: 4), "End game → the score")
    }

    // MARK: - ProCameraSpace

    func testLowSpaceLowBatteryAndWatchOffShowInTheStatus() {
        launch(freeGB: "4", battery: "9", ["-uiTestWatchOff"])
        openCamera()
        chooseQuality("uhd4k-30")
        startGameByGame()
        let title = any("racket.camera.recTitle")
        XCTAssertTrue(title.label.hasSuffix("min left · 9% · Watch off"), title.label)
        let banner = any("racket.camera.lowSpace")
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        XCTAssertTrue(banner.label.hasPrefix("About "), banner.label)
        XCTAssertTrue(banner.label.hasSuffix(" of space left"), banner.label)
        XCTAssertEqual(app.buttons["racket.camera.nextFormat"].label, "HD · 30 from next game")
        XCTAssertTrue(app.buttons["racket.camera.freeSpace"].exists)
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"))
        shot("ProCameraSpace")
        app.buttons["racket.camera.freeSpace"].tap()
        XCTAssertTrue(app.buttons["racket.storage.cancel"].waitForExistence(timeout: 4), "Free space opens the storage screen")
        app.buttons["racket.storage.cancel"].tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 4))
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"), "still recording")
    }

    func testNoSpaceMeansTheShutterWontStart() {
        launch(freeGB: "0.55")
        openCamera()
        XCTAssertTrue(any("racket.camera.status").label.hasPrefix("No space"), any("racket.camera.status").label)
        XCTAssertFalse(app.buttons["racket.camera.shutter"].isEnabled)
    }

    // MARK: - ProCameraEverything

    func testEverythingModeNewGameMarkAndStop() {
        launch()
        openCamera(everything: true)
        app.buttons["racket.camera.shutter"].tap()
        XCTAssertTrue(app.buttons["racket.storage.continue"].waitForExistence(timeout: 6))
        app.buttons["racket.storage.continue"].tap()
        let status = any("racket.rec.status")
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(status.label.hasPrefix("Recording"), status.label)
        XCTAssertEqual(any("racket.camera.recTitle").label, "Match · saves every 10 min", "the fake never saves a part")
        XCTAssertEqual(app.buttons["racket.rec.newGame"].label, "New game starts")
        XCTAssertTrue(app.buttons["racket.rec.tagLast"].exists)
        XCTAssertTrue(app.buttons["racket.rec.mark"].exists)
        XCTAssertFalse(app.buttons["racket.camera.quality"].isEnabled)
        shot("ProCameraEverything")
        app.buttons["racket.rec.newGame"].tap()
        app.buttons["racket.rec.mark"].tap()
        app.buttons["racket.rec.show.dim"].tap()
        XCTAssertEqual(any("racket.rec.scoreCaption").label, "Games")
        app.buttons["racket.rec.show.camera"].tap()
        app.buttons["racket.rec.stop"].tap()
        XCTAssertTrue(any("racket.split.recorded").waitForExistence(timeout: 6), "stop → the split prompt")
        XCTAssertTrue(any("racket.split.line").label.hasPrefix("Looks like 2 games"), any("racket.split.line").label)
    }

    // MARK: - ProCameraDrill

    func testDrillUsesTheCameraBeforeAndDuringABlock() {
        launch()
        openRacket()
        app.segmentedControls["racket.mode"].buttons["Drill"].tap()
        app.buttons["racket.next"].tap()
        let drill = app.buttons["racket.drill"].firstMatch
        XCTAssertTrue(drill.waitForExistence(timeout: 5))
        drill.tap()
        tapWhenHittable(app.buttons["racket.recording.byUnit"])
        tapWhenHittable(app.buttons["racket.plan.row.focus"])
        tapWhenHittable(app.buttons["racket.custom.practising.Robot"])
        tapWhenHittable(app.buttons["racket.custom.stroke.Topspin"])
        app.buttons["racket.custom.save"].tap()
        tapWhenHittable(app.buttons["racket.plan.start"])

        // The pro camera before block 1: lenses and quality, no mode strip.
        let shutter = app.buttons["racket.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 25), "a drill opens on the pro camera")
        XCTAssertTrue(app.buttons["racket.camera.lens.3"].exists)
        XCTAssertFalse(app.buttons["racket.camera.mode.byUnit"].exists, "a drill's mode was chosen in setup")
        app.buttons["racket.camera.lens.2"].tap()
        shutter.tap()
        XCTAssertTrue(any("racket.rec.countdown").waitForExistence(timeout: 4), "the countdown to block 1")

        // ProCameraDrill: the block on the camera.
        let end = app.buttons["racket.rec.endBlock"]
        XCTAssertTrue(end.waitForExistence(timeout: 12), "block 1 starts after the countdown")
        XCTAssertEqual(any("racket.drill.header").label, "Block 1 of 3")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("● Recording"), any("racket.rec.status").label)
        XCTAssertTrue((any("racket.rec.status").value as? String ?? "").hasSuffix(" left"))
        XCTAssertTrue(app.buttons["racket.rec.pause"].exists)
        XCTAssertTrue(app.buttons["racket.rec.mark"].exists)
        XCTAssertTrue(app.buttons["racket.camera.lens.2"].isSelected, "the lens chosen before carries into the block")
        shot("ProCameraDrill")
        app.buttons["racket.rec.mark"].tap()
        app.buttons["racket.rec.pause"].tap()
        XCTAssertTrue(app.buttons["racket.paused.resume"].waitForExistence(timeout: 4))
        app.buttons["racket.paused.resume"].tap()
        XCTAssertTrue(end.waitForExistence(timeout: 4))
        end.tap()
        XCTAssertTrue(app.buttons["racket.rec.pauseRest"].waitForExistence(timeout: 4), "End block → rest")
    }

    // MARK: - ProCameraLandscape

    func testSidewaysCameraBeforeAndWhileRecording() {
        launch(freeGB: "45", battery: "82", ["-uiTestRacketLandscape", "YES"])
        openCamera(setServer: false)
        sleep(2)
        let frame = app.windows.firstMatch.frame
        print("DIAG window=\(frame) shutter=\(app.buttons["racket.camera.shutter"].frame) lens=\(app.buttons["racket.camera.lens.1"].frame)")
        shot("ProCameraLandscape")
        XCTAssertGreaterThan(frame.width, frame.height, "the app turned sideways")
        XCTAssertTrue(app.buttons["racket.camera.shutter"].exists)
        XCTAssertTrue(app.buttons["racket.camera.lens.1"].exists)
        XCTAssertEqual(any("racket.camera.status").label, "Ready · 12 h · 82%")
        let shutter = app.buttons["racket.camera.shutter"].frame
        XCTAssertGreaterThan(shutter.midX, frame.width * 0.75, "controls down the right edge")
        shot("ProCameraLandscape")
        app.buttons["racket.camera.shutter"].tap()
        XCTAssertTrue(any("racket.game.status").waitForExistence(timeout: 8))
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"))
        XCTAssertGreaterThan(app.buttons["racket.game.stop"].frame.midX, frame.width * 0.75)
        shot("ProCameraLandscapeRecording")
    }
}
