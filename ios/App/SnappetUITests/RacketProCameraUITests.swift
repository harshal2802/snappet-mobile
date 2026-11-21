import XCTest

/// UI coverage for the **racket pro camera, before recording** (prompt 255, issue #448 part 2; boards ProCamera →
/// ProCameraDenied): the status pill and quality label, lens buttons, the zoom dial (drag across the lenses) and pinch,
/// tap to focus with the brightness slider, touch and hold for AE/AF lock, the Video quality page (only the formats the
/// camera has), Options (framing, who serves, show, Watch, live tracking, Looks, Compare quality), the preview-only Looks
/// strip, the no-access state, and the shutter starting game by game.
///
/// On the simulator the camera is the fake (`-uiTestFakeCamera`) with a fake capability set (`-uiTestCameraLenses`,
/// `-uiTestCameraFormats`, `-uiTestCameraFreeGB`, `-uiTestCameraBattery`). Built for a phone, the suite uses the real
/// camera and reads what it reports; it never taps the shutter there. `RACKET_SHOTS=<dir>` writes the board screenshots.
@MainActor
final class RacketProCameraUITests: XCTestCase {
    var app: XCUIApplication!

    #if targetEnvironment(simulator)
    private let onPhone = false
    #else
    private let onPhone = true
    #endif

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestWatchReady"]
        if !onPhone {
            app.launchArguments += ["-uiTestFakeCamera", "-uiTestCameraFreeGB", "45", "-uiTestCameraBattery", "82"]
            app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
        }
        app.launchArguments += extra
        app.launchOnTestStore()
    }

    private func shot(_ name: String) {
        if onPhone, app.state == .runningForeground {
            // On a phone there is no shared folder: keep the app's own window in the result bundle.
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = name; a.lifetime = .keepAlways; add(a)
        }
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

    /// Match form → Set up camera → the pro camera.
    private func openCamera(opponent: String? = "Alex") {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        XCTAssertTrue(app.startQuickSession(), "Quick Start opens an empty session")
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        let tt = app.buttons["racket.sport.tableTennis"]
        XCTAssertTrue(tt.waitForExistence(timeout: 5))
        tt.tap()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
        if let opponent {
            let field = app.textFields["racket.opponent"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("\(opponent)\n")
        }
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])
    }

    private var preview: XCUIElement { any("racket.camera.preview") }

    /// The screen's elements with an identifier, from ONE snapshot. The focus square with its sun and the zoom dial
    /// fade 2–3 s after the last touch, and on a slow runner a few separate queries take that long: a label read
    /// after the overlay has gone fails the test with "no matches". Values read from one snapshot can't.
    private func onScreen() -> [String: any XCUIElementSnapshot] {
        guard let root = try? app.snapshot() else { return [:] }
        var out: [String: any XCUIElementSnapshot] = [:]
        func walk(_ s: any XCUIElementSnapshot) {
            if !s.identifier.isEmpty, out[s.identifier] == nil { out[s.identifier] = s }
            s.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Drags up from the middle of `el` as it was in `shown`, through the preview's coordinates (the preview never
    /// goes away), so an overlay that faded in the meantime can't fail the gesture; the caller checks the outcome.
    private func dragUp(on el: any XCUIElementSnapshot, in shown: [String: any XCUIElementSnapshot]) {
        guard let p = shown["racket.camera.preview"]?.frame else { return }
        let start = preview.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: el.frame.midX - p.minX, dy: el.frame.midY - p.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)))
    }

    /// A point on the preview, in its own unit coordinates.
    private func previewPoint(_ x: Double, _ y: Double) -> XCUICoordinate {
        preview.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    // MARK: - ProCamera, ProCameraZoom

    func testCameraReadyWithLensesDialAndPinch() throws {
        try XCTSkipIf(onPhone, "it checks the fake camera's numbers; the phone's own are covered by testReportsWhatThisCameraHas")
        launch(["-uiTestCameraLenses", "0.5,1,2,3"])
        openCamera()
        let shutter = app.buttons["racket.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), "Set up camera opens the pro camera")
        XCTAssertEqual(shutter.label, "Start recording")
        XCTAssertEqual(any("racket.camera.status").label, "Ready · 12 h · 82%", "45 GB at HD · 30, 82 % battery")
        XCTAssertEqual(app.buttons["racket.camera.quality"].label, "Video quality HD · 30")
        for l in ["0.5", "1", "2", "3"] { XCTAssertTrue(app.buttons["racket.camera.lens.\(l)"].exists, "lens \(l)") }
        XCTAssertEqual(app.buttons["racket.camera.lens.1"].label, "Zoom 1×")
        XCTAssertTrue(app.buttons["racket.camera.lens.1"].isSelected)
        XCTAssertEqual(app.buttons["racket.camera.mode.byUnit"].label, "GAME BY GAME")
        XCTAssertTrue(app.buttons["racket.camera.mode.byUnit"].isSelected)
        XCTAssertEqual(app.buttons["racket.camera.mode.everything"].label, "EVERYTHING")
        XCTAssertTrue(app.buttons["racket.camera.videos"].exists, "the thumbnail opens Your videos")
        XCTAssertTrue(app.buttons["racket.camera.options"].exists)
        XCTAssertTrue(any("racket.camera.grid").exists, "Grid is on by default")
        XCTAssertEqual(any("racket.camera.level").label, "Level", "the fake stands level")
        shot("ProCamera")

        // A lens tap jumps there; the selected button shows the zoom.
        app.buttons["racket.camera.lens.2"].tap()
        XCTAssertTrue(app.buttons["racket.camera.lens.2"].isSelected)
        XCTAssertEqual(app.buttons["racket.camera.lens.2"].label, "Zoom 2×")
        app.buttons["racket.camera.lens.1"].tap()

        // Drag across the lens buttons: the dial opens and the zoom follows the finger.
        let from = app.buttons["racket.camera.lens.1"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 50, dy: 0)))
        let dial = any("racket.camera.dial")
        XCTAssertTrue(dial.waitForExistence(timeout: 3), "dragging the lenses opens the zoom dial")
        XCTAssertTrue(any("racket.camera.pinchHint").exists, "Pinch works too")
        let zoomed = app.buttons["racket.camera.lens.1"].label
        XCTAssertTrue(zoomed.hasPrefix("Zoom 1."), "between 1× and 2× after a short drag: \(zoomed)")
        shot("ProCameraZoom")

        // A touch on the dial keeps it open. It fades 2 s after the last touch, which the checks above can outlast on
        // a slow runner: open it again from the lenses if it has gone, then touch it where one snapshot saw it.
        var shown = onScreen()
        if shown["racket.camera.dial"] == nil {
            from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 20, dy: 0)))
            _ = dial.waitForExistence(timeout: 3)
            shown = onScreen()
        }
        let dialShown = try XCTUnwrap(shown["racket.camera.dial"], "dragging the lenses opens the zoom dial")
        dragUp(on: dialShown, in: shown)
        // The dial fades by itself.
        XCTAssertTrue(dial.waitForNonExistence(timeout: 6), "the dial hides after a moment")

        // Pinch on the preview zooms too.
        app.buttons["racket.camera.lens.1"].tap()
        preview.pinch(withScale: 2.5, velocity: 2)
        let pinched = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'racket.camera.lens.' AND selected == true")).firstMatch
        XCTAssertTrue(pinched.waitForExistence(timeout: 3))
        XCTAssertNotEqual(pinched.label, "Zoom 1×", "pinching changed the zoom")
    }

    func testOnlyTheLensesThePhoneHasAreShown() throws {
        try XCTSkipIf(onPhone, "it checks the fake camera's numbers; the phone's own are covered by testReportsWhatThisCameraHas")
        launch(["-uiTestCameraLenses", "1"])
        openCamera()
        XCTAssertTrue(app.buttons["racket.camera.shutter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["racket.camera.lens.1"].exists)
        XCTAssertFalse(app.buttons["racket.camera.lens.0.5"].exists, "no ultra-wide, no 0.5")
        XCTAssertFalse(app.buttons["racket.camera.lens.2"].exists)
        XCTAssertFalse(app.buttons["racket.camera.lens.3"].exists)
    }

    // MARK: - ProCameraFocus, ProCameraLock

    func testTapFocusesAndTouchAndHoldLocks() {
        launch(["-uiTestCameraLenses", "0.5,1,2,3"])
        openCamera()
        XCTAssertTrue(app.buttons["racket.camera.shutter"].waitForExistence(timeout: 10))
        // The square and the sun fade 3 s after the last touch (a drag on the sun is a touch). Read them from one
        // snapshot and drag the sun where it was; if they faded first, the drag misses, so tap to focus again.
        let square = any("racket.camera.focus")
        let brighter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'racket.camera.exposure' AND value != '0'")).firstMatch
        var brightened = false
        for _ in 0..<3 where !brightened {
            previewPoint(0.55, 0.45).tap()
            XCTAssertTrue(square.waitForExistence(timeout: 3), "a tap on the camera always focuses")
            let shown = onScreen()
            guard let squareShown = shown["racket.camera.focus"], let sun = shown["racket.camera.exposure"] else { continue }
            XCTAssertEqual(squareShown.label, "Focus")
            XCTAssertEqual(sun.value as? String, "0", "the brightness starts at 0")
            dragUp(on: sun, in: shown)
            brightened = brighter.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(brightened, "the brightness slider sits beside the square; dragging the sun up brightens")
        shot("ProCameraFocus")
        XCTAssertTrue(square.waitForNonExistence(timeout: 8), "the square fades after a few seconds")
        XCTAssertFalse(any("racket.camera.lockBadge").exists)

        // Touch and hold: AE/AF LOCK, with the caption; a tap anywhere unlocks.
        previewPoint(0.55, 0.45).press(forDuration: 1.2)
        let badge = any("racket.camera.lockBadge")
        XCTAssertTrue(badge.waitForExistence(timeout: 3), "touch and hold locks focus and exposure")
        XCTAssertEqual(badge.label, "AE/AF LOCK")
        XCTAssertTrue(any("racket.camera.lockCaption").exists)
        XCTAssertEqual(any("racket.camera.lockCaption").label, "Stays fixed when players move. Tap anywhere to unlock.")
        XCTAssertEqual(preview.value as? String, "Focus and exposure locked")
        shot("ProCameraLock")
        previewPoint(0.3, 0.3).tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 3), "a tap anywhere unlocks")
        XCTAssertEqual(preview.value as? String, "Auto focus")
    }

    // MARK: - ProCameraQuality

    func testQualityPageListsOnlySupportedFormatsWithEstimates() throws {
        try XCTSkipIf(onPhone, "it checks the fake camera's numbers; the phone's own are covered by testReportsWhatThisCameraHas")
        launch(["-uiTestCameraFormats", "hd1080-30,hd1080-60,uhd4k-30"])
        openCamera()
        let quality = app.buttons["racket.camera.quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: 10))
        quality.tap()
        XCTAssertTrue(app.buttons["racket.camera.quality.hd1080-30"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.camera.quality.hd1080-60"].exists)
        XCTAssertTrue(app.buttons["racket.camera.quality.uhd4k-30"].exists)
        XCTAssertFalse(app.buttons["racket.camera.quality.uhd4k-60"].exists, "a format the camera lacks is not offered")
        XCTAssertTrue(app.buttons["racket.camera.quality.hd1080-30"].isSelected)
        XCTAssertEqual(any("racket.camera.qualityLine.hd1080-30").label, "12 h · 3.7 GB/h")
        XCTAssertEqual(any("racket.camera.qualityLine.uhd4k-30").label, "4 h 10 min · 10.3 GB/h")
        XCTAssertTrue(app.staticTexts["Smoother slow motion. Warms the phone sooner."].exists)
        XCTAssertTrue(app.staticTexts["Sharper zoom in the player. Warms the phone sooner."].exists)
        XCTAssertEqual(any("racket.camera.qualityFootnote").label,
                       "Based on 45 GB free. The estimate tightens once recording has run for a minute.")
        XCTAssertEqual(any("racket.camera.qualityRallyLine").label, "Rally finding works the same at every quality.")
        XCTAssertFalse(app.buttons["racket.camera.everyMatch"].isSelected, "Off: this match only")
        app.buttons["racket.camera.quality.uhd4k-30"].tap()
        XCTAssertTrue(app.buttons["racket.camera.quality.uhd4k-30"].isSelected)
        app.buttons["racket.camera.qualityDone"].tap()
        XCTAssertTrue(quality.waitForExistence(timeout: 4))
        XCTAssertEqual(quality.label, "Video quality 4K · 30")
        XCTAssertEqual(any("racket.camera.status").label, "Ready · 4 h · 82%", "the pill follows the quality")

        // Back discards a pick.
        quality.tap()
        XCTAssertTrue(app.buttons["racket.camera.quality.hd1080-60"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.quality.hd1080-60"].tap()
        app.buttons["racket.camera.qualityBack"].tap()
        XCTAssertTrue(quality.waitForExistence(timeout: 4))
        XCTAssertEqual(quality.label, "Video quality 4K · 30")
    }

    func testQualityPageMatchesTheBoardWithAllFour() throws {
        try XCTSkipIf(onPhone, "it saves the default quality; the phone's own settings are left alone")
        launch()
        openCamera()
        let quality = app.buttons["racket.camera.quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: 10))
        quality.tap()
        XCTAssertTrue(app.buttons["racket.camera.quality.uhd4k-60"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Likely to overheat in a long match. Best for short drills."].exists)
        XCTAssertTrue(app.staticTexts["HD · 30 (1080p)"].exists)
        shot("ProCameraQuality")
        // "Use for every match" saves it as the default the camera opens on next time.
        app.buttons["racket.camera.quality.hd1080-60"].tap()
        app.buttons["racket.camera.everyMatch"].tap()
        XCTAssertTrue(app.buttons["racket.camera.everyMatch"].isSelected)
        app.buttons["racket.camera.qualityDone"].tap()
        XCTAssertEqual(quality.label, "Video quality HD · 60")
        app.buttons["racket.camera.close"].tap()
        tapWhenHittable(app.buttons["racket.page.setUpCamera"])
        XCTAssertTrue(quality.waitForExistence(timeout: 10))
        XCTAssertEqual(quality.label, "Video quality HD · 60", "opens on the quality saved for every match")
        // Put the default back (HD · 30) for the suites after this one.
        quality.tap()
        XCTAssertTrue(app.buttons["racket.camera.quality.hd1080-30"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.quality.hd1080-30"].tap()
        if !app.buttons["racket.camera.everyMatch"].isSelected { app.buttons["racket.camera.everyMatch"].tap() }
        app.buttons["racket.camera.qualityDone"].tap()
        XCTAssertEqual(quality.label, "Video quality HD · 30")
    }

    // MARK: - ProCameraOptions, ProCameraLooks

    func testOptionsSheetFramingServeShowWatchAndLooks() {
        launch(["-uiTestCameraLenses", "0.5,1,2,3"])
        openCamera()
        XCTAssertTrue(app.buttons["racket.camera.options"].waitForExistence(timeout: 10))
        app.buttons["racket.camera.options"].tap()
        let grid = app.buttons["racket.camera.framing.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 4))
        XCTAssertTrue(grid.isSelected)
        XCTAssertTrue(app.buttons["racket.camera.framing.level"].isSelected)
        XCTAssertFalse(app.buttons["racket.camera.framing.courtGuide"].isSelected)
        XCTAssertEqual(app.buttons["racket.camera.serve.us"].label, "You")
        XCTAssertEqual(app.buttons["racket.camera.serve.them"].label, "Alex")
        XCTAssertTrue(app.buttons["racket.camera.serve.skip"].isSelected, "Who serves first? Optional: Skip")
        XCTAssertTrue(app.buttons["racket.camera.show.camera"].isSelected, "While playing, show: Camera")
        XCTAssertTrue(app.buttons["racket.camera.options.watch"].isSelected, "Start and score from your Watch")
        XCTAssertTrue(app.staticTexts["Watch linked"].exists)
        let tracking = any("racket.camera.options.tracking")
        XCTAssertFalse(tracking.isEnabled, "live tracking is not built")
        XCTAssertTrue(app.staticTexts["Not available yet"].exists)
        XCTAssertTrue(app.buttons["racket.camera.options.looks"].exists)
        XCTAssertTrue(app.buttons["racket.camera.options.compareQuality"].exists)
        shot("ProCameraOptions")

        // Court guide on; Grid off.
        app.buttons["racket.camera.framing.courtGuide"].tap()
        grid.tap()
        XCTAssertFalse(grid.isSelected)
        app.buttons["racket.camera.optionsDone"].tap()
        XCTAssertTrue(any("racket.camera.guide").waitForExistence(timeout: 4), "the court guide shows on the preview")
        XCTAssertFalse(any("racket.camera.grid").exists, "the grid is off")

        // Compare quality opens the Video quality page.
        app.buttons["racket.camera.options"].tap()
        XCTAssertTrue(app.buttons["racket.camera.options.compareQuality"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.framing.courtGuide"].tap()
        app.buttons["racket.camera.framing.grid"].tap()
        app.buttons["racket.camera.options.compareQuality"].tap()
        XCTAssertTrue(app.buttons["racket.camera.qualityBack"].waitForExistence(timeout: 5))
        app.buttons["racket.camera.qualityBack"].tap()

        // Looks: a preview-only strip above the shutter.
        XCTAssertTrue(app.buttons["racket.camera.options"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.options"].tap()
        XCTAssertTrue(app.buttons["racket.camera.options.looks"].waitForExistence(timeout: 4))
        app.buttons["racket.camera.options.looks"].tap()
        let vivid = app.buttons["racket.camera.look.vivid"]
        XCTAssertTrue(vivid.waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.camera.looksCaption").label, "Preview only. The video saves as filmed.")
        for l in ["original", "vivid", "warm", "cool", "bw"] {
            XCTAssertTrue(app.buttons["racket.camera.look.\(l)"].exists, l)
        }
        XCTAssertTrue(app.buttons["racket.camera.look.original"].isSelected)
        vivid.tap()
        XCTAssertTrue(vivid.isSelected)
        XCTAssertTrue(app.buttons["racket.camera.shutter"].exists, "the shutter stays")
        shot("ProCameraLooks")
        XCTAssertTrue(vivid.waitForNonExistence(timeout: 10), "the strip tucks away after a moment")
        XCTAssertTrue(app.buttons["racket.camera.lens.1"].exists, "the lenses come back")
    }

    // MARK: - ProCameraDenied

    func testNoAccessOffersSettingsAndPlayWithoutVideo() throws {
        try XCTSkipIf(onPhone, "the no-access state is driven by the fake camera")
        launch(["-uiTestCameraDenied"])
        openCamera()
        let title = any("racket.camera.denied")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Snappet can’t use the camera")
        XCTAssertTrue(app.staticTexts["Recording needs the camera, and saving needs Photos. Nothing else on your phone is read."].exists)
        XCTAssertTrue(app.buttons["racket.camera.openSettings"].exists)
        XCTAssertFalse(app.buttons["racket.camera.shutter"].exists)
        shot("ProCameraDenied")
        app.buttons["racket.camera.playWithoutVideo"].tap()
        XCTAssertTrue(app.buttons["racket.scoreOnly.us"].waitForExistence(timeout: 6), "the existing no-video path")
    }

    // MARK: - The shutter

    func testShutterStartsGameByGameAndEverythingGoesToTheStorageCheck() throws {
        try XCTSkipIf(onPhone, "never record on the phone from a test")
        launch()
        openCamera()
        let shutter = app.buttons["racket.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        // Everything → the existing storage check, Back returns to the camera.
        app.buttons["racket.camera.mode.everything"].tap()
        XCTAssertTrue(app.buttons["racket.camera.mode.everything"].isSelected)
        shutter.tap()
        XCTAssertTrue(app.buttons["racket.storage.cancel"].waitForExistence(timeout: 6))
        app.buttons["racket.storage.cancel"].tap()
        XCTAssertTrue(shutter.waitForExistence(timeout: 4))
        // Game by game → recording starts on the game screen.
        app.buttons["racket.camera.mode.byUnit"].tap()
        sleep(1)
        shutter.tap()
        let status = any("racket.game.status")
        XCTAssertTrue(status.waitForExistence(timeout: 6))
        XCTAssertTrue(status.label.hasPrefix("Recording"), status.label)
    }

    func testThumbnailOpensYourVideos() throws {
        try XCTSkipIf(onPhone, "Your videos may show the phone's own videos")
        launch()
        openCamera()
        let videos = app.buttons["racket.camera.videos"]
        XCTAssertTrue(videos.waitForExistence(timeout: 10))
        videos.tap()
        XCTAssertTrue(app.buttons["racket.videos.close"].waitForExistence(timeout: 6), "Your videos opens over the camera")
        app.buttons["racket.videos.close"].tap()
        XCTAssertTrue(app.buttons["racket.camera.shutter"].waitForExistence(timeout: 6), "back on the camera")
    }

    // MARK: - On the phone: what the real camera reports (no recording)

    func testReportsWhatThisCameraHas() {
        launch()
        openCamera()
        let shutter = app.buttons["racket.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        sleep(2)   // the camera configures off the main thread
        let lenses = ["0.5", "1", "2", "3", "5"].filter { app.buttons["racket.camera.lens.\($0)"].exists }
        print("CAMERA-REPORT lenses=\(lenses)")
        print("CAMERA-REPORT status=\(any("racket.camera.status").label) quality=\(app.buttons["racket.camera.quality"].label)")
        XCTAssertTrue(lenses.contains("1"))

        // Each lens, and the zoom range at both ends of the dial.
        for l in lenses {
            app.buttons["racket.camera.lens.\(l)"].tap()
            sleep(1)
            print("CAMERA-REPORT lens \(l) -> \(app.buttons["racket.camera.lens.\(l)"].label) selected=\(app.buttons["racket.camera.lens.\(l)"].isSelected)")
        }
        let first = app.buttons["racket.camera.lens.\(lenses.first!)"]
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 600, dy: 0)))
        let dial = any("racket.camera.dial")
        if dial.waitForExistence(timeout: 2) { print("CAMERA-REPORT max zoom=\(dial.value as? String ?? "?")") }
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -600, dy: 0)))
        if dial.waitForExistence(timeout: 2) { print("CAMERA-REPORT min zoom=\(dial.value as? String ?? "?")") }
        app.buttons["racket.camera.lens.1"].tap()
        sleep(1)
        shot("phone-camera")

        // Focus, brightness and lock.
        previewPoint(0.5, 0.45).tap()
        let square = any("racket.camera.focus")
        print("CAMERA-REPORT focus square=\(square.waitForExistence(timeout: 3))")
        any("racket.camera.exposure").swipeUp()
        print("CAMERA-REPORT bias=\(any("racket.camera.exposure").value as? String ?? "?")")
        previewPoint(0.5, 0.45).press(forDuration: 1.2)
        print("CAMERA-REPORT lock badge=\(any("racket.camera.lockBadge").waitForExistence(timeout: 3)) value=\(preview.value as? String ?? "?")")
        shot("phone-lock")
        previewPoint(0.3, 0.3).tap()
        print("CAMERA-REPORT unlocked=\(any("racket.camera.lockBadge").waitForNonExistence(timeout: 3))")

        // Every quality the camera offers: pick it, Done, and read the label back.
        let quality = app.buttons["racket.camera.quality"]
        quality.tap()
        XCTAssertTrue(app.buttons["racket.camera.qualityDone"].waitForExistence(timeout: 5))
        let keys = ["hd1080-30", "hd1080-60", "uhd4k-30", "uhd4k-60"].filter { app.buttons["racket.camera.quality.\($0)"].exists }
        for k in keys { print("CAMERA-REPORT format \(k) line=\(any("racket.camera.qualityLine.\(k)").label)") }
        print("CAMERA-REPORT footnote=\(any("racket.camera.qualityFootnote").label)")
        app.buttons["racket.camera.qualityBack"].tap()
        for k in keys {
            XCTAssertTrue(quality.waitForExistence(timeout: 5))
            quality.tap()
            XCTAssertTrue(app.buttons["racket.camera.quality.\(k)"].waitForExistence(timeout: 5))
            app.buttons["racket.camera.quality.\(k)"].tap()
            app.buttons["racket.camera.qualityDone"].tap()
            sleep(2)
            print("CAMERA-REPORT switched \(k) -> label=\(quality.label) status=\(any("racket.camera.status").label) shutter=\(shutter.exists)")
        }
        quality.tap()
        app.buttons["racket.camera.quality.hd1080-30"].tap()
        app.buttons["racket.camera.qualityDone"].tap()
        // Leave without recording.
        app.buttons["racket.camera.close"].tap()
    }
}
