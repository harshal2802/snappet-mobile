import XCTest

/// UI coverage for the **Watch-mode racket player** (prompt 253, issue #448 part 1). Seeded by
/// `-uiTestSeedRacketVideos -uiTestRacketPlayer <variant>`: the match filmed game by game, game 1 (5:00) with 21
/// rallies over a synthetic bundled clip (a drawn table and ball), game 2 (1:00) with none.
///
/// `testBoardWalk` is the screenshot walk for the board check: it logs `RACKETSHOT:<name>:<delay>` lines and holds
/// still, and a script reading the xcodebuild log takes a simulator screenshot for each. Run on its own with
/// `-only-testing:SnappetUITests/RacketPlayerUITests/testBoardWalk`; it passes without the script too.
@MainActor
final class RacketPlayerUITests: XCTestCase {
    var app: XCUIApplication!

    private func launch(_ variant: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketPlayer", variant]
        app.launchOnTestStore()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var surface: XCUIElement { any("racket.player.surface") }
    private var controls: XCUIElement { app.buttons["racket.player.playPause"] }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    /// History → the seeded session → Your videos → Play on row `k`.
    private func openPlayer(row k: Int = 0) {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded session")
        row.tap()
        tapWhenHittable(app.buttons["racket.recap.videos"])
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6))
        tapWhenHittable(app.buttons["racket.videos.play.\(k)"])
        XCTAssertTrue(surface.waitForExistence(timeout: 8) || any("racket.player.missing.title").exists, "the Watch-mode player")
    }

    /// The player's auto-hiding controls, driven without racing the hide (shared: `RacketPlayerControls`).
    private var player: RacketPlayerControls { RacketPlayerControls(app: app) }
    private func tapVideo(dx: CGFloat = 0.5) { player.tapVideo(dx: dx) }
    private func showControls(file: StaticString = #filePath, line: UInt = #line) { player.freshControls(file: file, line: line) }
    private func playPause(_ label: String) -> XCUIElement { player.playPause(label) }
    private func tapControl(_ el: XCUIElement, until shows: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        player.tapControl(el, until: shows, file: file, line: line)
    }
    private func pause(file: StaticString = #filePath, line: UInt = #line) { player.pause(file: file, line: line) }

    /// With the controls showing and paused: back to the first rally, then forward to rally `n`.
    private func goToRally(_ n: Int) {
        let prev = app.buttons["racket.player.prevRally"], next = app.buttons["racket.player.nextRally"]
        for _ in 0..<30 where prev.isEnabled { prev.tap() }
        // Portrait has the label line; landscape only the one-line title ("… · Rally 12 of 21").
        func at(_ k: Int) -> Bool {
            let label = any("racket.player.label")
            return label.exists ? label.label.hasPrefix("Rally \(k) ") : any("racket.player.title").label.contains("Rally \(k) of")
        }
        for _ in 0..<(n - (at(1) ? 1 : 0)) { next.tap() }
        XCTAssertTrue(at(n), "at rally \(n)")
    }

    /// "00:12 / 05:00" → seconds into the part.
    private func seconds(_ el: XCUIElement) -> Int {
        let s = (el.value as? String ?? "").components(separatedBy: " / ").first ?? ""
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : -1
    }

    private func shot(_ name: String, delay: Double = 0.6, hold: Double = 2.5) {
        print("RACKETSHOT:\(name):\(delay)")
        Thread.sleep(forTimeInterval: hold)
    }

    // MARK: Watch mode

    func testTapTogglesControlsSpeedMenuSkipAndModes() {
        launch("portrait")
        openPlayer()
        // It opens playing with the controls showing; they hide by themselves while playing.
        // One query for "showing and reads Pause": reading the label after a separate existence check can land after
        // the auto-hide on a slow runner.
        XCTAssertTrue(playPause("Pause").waitForExistence(timeout: 4), "Play opens playing, with the controls showing")
        XCTAssertTrue(controls.waitForNonExistence(timeout: 8), "the controls hide by themselves while playing")
        XCTAssertTrue(any("racket.player.progress").exists, "the thin progress line stays")

        // Tap shows them, tap again hides them.
        tapVideo()
        XCTAssertTrue(controls.waitForExistence(timeout: 2))
        tapVideo()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 3))

        // Paused, they stay.
        pause()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(controls.exists, "paused: the controls stay")
        XCTAssertEqual(app.buttons["racket.player.back"].label, "Videos")
        XCTAssertTrue(app.buttons["racket.player.share"].exists)
        XCTAssertTrue(app.buttons["racket.player.edit"].exists)
        XCTAssertTrue(any("racket.player.strip").exists)
        XCTAssertTrue(app.buttons["racket.player.mute"].exists)

        // Previous / next rally → rally 2; the label line says so.
        goToRally(2)
        XCTAssertTrue(any("racket.player.label").label.hasPrefix("Rally 2 · You won"), any("racket.player.label").label)
        XCTAssertTrue(any("racket.player.subtitle").label.hasSuffix("Rally 2 of 21"), any("racket.player.subtitle").label)

        // Speed menu: 0.5× → the button and, with the controls hidden, a small label.
        app.buttons["racket.player.speed"].tap()
        XCTAssertTrue(app.buttons["racket.player.speed.0.5"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["racket.player.loop"].exists)
        XCTAssertTrue(app.buttons["racket.player.ralliesOnly"].exists)
        app.buttons["racket.player.speed.0.5"].tap()
        XCTAssertEqual(app.buttons["racket.player.speed"].label, "Speed")
        XCTAssertEqual(app.buttons["racket.player.speed"].value as? String, "0.5×")
        app.buttons["racket.player.speed"].tap()
        app.buttons["racket.player.loop"].tap()
        tapVideo()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 3))
        XCTAssertEqual(any("racket.player.badge.0").label, "Loop · rally 2")
        XCTAssertEqual(any("racket.player.badge.1").label, "0.5×")
        XCTAssertEqual(any("racket.player.scorePill").label, "2 – 0")

        // Double-tap the right half: +10 s, the ripple, and the controls stay hidden (the toggle is undone).
        let before = seconds(surface)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.33)).doubleTap()
        let ripple = any("racket.player.skipLabel")
        if ripple.waitForExistence(timeout: 1) { XCTAssertEqual(ripple.label, "+10 s") }   // shown for about a second
        XCTAssertGreaterThanOrEqual(seconds(surface) - before, 9, "skipped 10 s")
        XCTAssertFalse(controls.exists, "a double tap leaves the controls as they were")
        XCTAssertEqual(any("racket.player.badge.0").label, "0.5×", "skipping out of the rally ends the loop")
        Thread.sleep(forTimeInterval: 1)

        // Double-tap the left half: back 10 s.
        let mid = seconds(surface)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.33)).doubleTap()
        XCTAssertLessThanOrEqual(seconds(surface) - mid, -9)
        Thread.sleep(forTimeInterval: 1)

        // Rallies only from the menu.
        showControls()
        app.buttons["racket.player.speed"].tap()
        app.buttons["racket.player.ralliesOnly"].tap()
        XCTAssertTrue(app.buttons["racket.player.ralliesOnly"].waitForNonExistence(timeout: 2), "the menu closes")
        tapVideo()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 3))
        XCTAssertEqual(any("racket.player.badge.0").label, "Rallies only")

        // Pinch zooms; Reset returns.
        surface.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(any("racket.player.zoomLabel").waitForExistence(timeout: 3))
        app.buttons["racket.player.zoomReset"].tap()
        XCTAssertTrue(any("racket.player.zoomLabel").waitForNonExistence(timeout: 3))

        // Edit opens Edit mode (prompt 254) on the same video; Cancel with no changes goes straight back.
        showControls()
        app.buttons["racket.player.edit"].tap()
        XCTAssertTrue(app.buttons["racket.edit.done"].waitForExistence(timeout: 5))
        app.buttons["racket.edit.cancel"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
    }

    func testNoRalliesAndEndOfGame() {
        launch("portrait")
        openPlayer(row: 1)
        pause()
        XCTAssertEqual(any("racket.player.subtitle").label, "No score yet")
        XCTAssertEqual(any("racket.player.label").label, "No rallies marked yet")
        XCTAssertTrue(app.buttons["racket.player.findRallies"].exists)
        XCTAssertFalse(app.buttons["racket.player.nextRally"].isEnabled)

        // The end of game 2 (playing, skip to the end): Replay only (it is the last game).
        controls.tap()
        for _ in 0..<7 { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.33)).doubleTap() }
        Thread.sleep(forTimeInterval: 1)   // past the skip streak, so the next tap is a tap
        XCTAssertTrue(app.buttons["racket.player.replay"].waitForExistence(timeout: 8), "PlayerEnd")
        XCTAssertFalse(app.buttons["racket.player.nextGame"].exists, "no game after the last")
        XCTAssertEqual(any("racket.player.label").label, "Game 2 ended")
        XCTAssertEqual(controls.label, "Play")

        // Mark by hand opens the timeline.
        app.buttons["racket.player.markByHand"].tap()
        XCTAssertTrue(app.buttons["racket.tl.markStart"].waitForExistence(timeout: 5))
    }

    func testMissingOriginalKeepsTheStats() {
        launch("missing")
        openPlayer()
        XCTAssertTrue(any("racket.player.missing.title").waitForExistence(timeout: 8))
        XCTAssertEqual(any("racket.player.missing.title").label, "This video is no longer in Photos")
        XCTAssertEqual(any("racket.player.subtitle").label, "Video missing")
        XCTAssertFalse(app.buttons["racket.player.missing.relink"].isEnabled, "relink is not built yet, and says so")
        XCTAssertFalse(app.buttons["racket.player.share"].isEnabled)
        app.buttons["racket.player.missing.keep"].tap()
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 5), "back to Your videos")
    }

    // MARK: Screenshot walk (board check)

    func testBoardWalk() {
        launch("portrait")
        openPlayer()
        pause()
        goToRally(12)
        app.buttons["racket.player.nextRally"].tap()
        app.buttons["racket.player.prevRally"].tap()
        // Two seconds into rally 12.
        controls.tap()
        Thread.sleep(forTimeInterval: 1.5)
        pause()
        shot("PlayerPaused")
        controls.tap()
        shot("PlayerChrome", delay: 0.2, hold: 0.8)
        XCTAssertTrue(controls.waitForNonExistence(timeout: 6))
        pause()
        tapVideo()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 3))
        shot("Main")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.33)).doubleTap()
        shot("PlayerSkip", delay: 0.05, hold: 1.5)
        print("RACKETSHOT:PlayerHold:1.4")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 3)
        Thread.sleep(forTimeInterval: 1)
        // Back to rally 12, paused.
        pause()
        app.buttons["racket.player.nextRally"].tap()
        app.buttons["racket.player.prevRally"].tap()
        for _ in 0..<3 where !any("racket.player.label").label.hasPrefix("Rally 12 ") { app.buttons["racket.player.prevRally"].tap() }
        // Scrub from rally 12's start: drag the strip left about 16 s (into untagged rally 13), then hold still.
        let strip = any("racket.player.strip")
        print("RACKETSHOT:PlayerScrub:1.6")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 3)
        Thread.sleep(forTimeInterval: 1)
        app.buttons["racket.player.prevRally"].tap()
        if !any("racket.player.label").label.hasPrefix("Rally 12") { app.buttons["racket.player.prevRally"].tap() }
        // Speed menu with 0.5× picked, playing.
        app.buttons["racket.player.speed"].tap()
        app.buttons["racket.player.speed.0.5"].tap()
        controls.tap()
        tapControl(app.buttons["racket.player.speed"], until: app.buttons["racket.player.loop"])
        shot("PlayerSpeed")
        // Loop this rally, controls hidden: the mode labels.
        app.buttons["racket.player.loop"].tap()
        tapVideo()
        shot("PlayerModes")
        // Pinch.
        surface.pinch(withScale: 2.4, velocity: 1.5)
        shot("PlayerZoom")
        app.buttons["racket.player.zoomReset"].tap()
        // End of game 1: loop off, 2×, last rally, then skip to the end.
        // Playing here: the controls hide by themselves, so pause for the menu and the rally steps, then play.
        pause()
        app.buttons["racket.player.speed"].tap()
        app.buttons["racket.player.loop"].tap()
        app.buttons["racket.player.speed"].tap()
        app.buttons["racket.player.speed.1"].tap()
        for _ in 0..<10 where app.buttons["racket.player.nextRally"].isEnabled { app.buttons["racket.player.nextRally"].tap() }
        controls.tap()
        XCTAssertTrue(playPause("Pause").waitForExistence(timeout: 2), "playing again")
        for _ in 0..<3 { surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.33)).doubleTap(); Thread.sleep(forTimeInterval: 0.8) }
        XCTAssertTrue(app.buttons["racket.player.replay"].waitForExistence(timeout: 15), "PlayerEnd")
        shot("PlayerEnd")
        app.buttons["racket.player.nextGame"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        pause()
        shot("PlayerNoRallies")
    }

    func testBoardWalkLetterbox() {
        launch("landscape")
        openPlayer()
        pause()
        goToRally(12)
        controls.tap()
        Thread.sleep(forTimeInterval: 1.5)
        pause()
        tapVideo()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 3))
        XCTAssertTrue(any("racket.player.turnHint").waitForExistence(timeout: 3), "a sideways video on an upright phone")
        shot("PlayerLetterbox")
    }

    /// Landscape: the headless simulator doesn't turn the app with `XCUIDevice.orientation`, so the app asks its scene
    /// to turn (`-uiTestRacketLandscape YES`, DEBUG only).
    func testBoardWalkLandscape() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketPlayer", "landscape",
                                "-uiTestRacketLandscape", "YES"]
        app.launchOnTestStore()
        openPlayer()
        Thread.sleep(forTimeInterval: 1.5)
        pause()
        // Paused at rally 12's start. (The portrait walks play it for 1.5 s first; here a pause costs a few seconds
        // more, see `tapControl`, and rally 12 is only 6.2 s long.)
        goToRally(12)
        XCTAssertTrue(any("racket.player.title").label.hasPrefix("Game 1 · 7 – 5 · Rally 12 of 21"), any("racket.player.title").label)
        XCTAssertFalse(any("racket.player.turnHint").exists)
        shot("PlayerLandscapeChrome")
        tapVideo()
        XCTAssertTrue(controls.waitForNonExistence(timeout: 3))
        XCTAssertTrue(any("racket.player.rallyPill").exists, "Rally 12 · 6.2 s beside the score")
        shot("PlayerLandscape")
    }

    func testBoardWalkStates() {
        launch("opening")
        openPlayer()
        XCTAssertTrue(any("racket.player.downloading").waitForExistence(timeout: 8))
        XCTAssertEqual(any("racket.player.downloading").label, "Downloading from iCloud · 42%")
        showControls()
        shot("PlayerOpening")
        app.terminate()
        launch("missing")
        openPlayer()
        XCTAssertTrue(any("racket.player.missing.title").waitForExistence(timeout: 8))
        shot("PlayerMissing")
    }
}
