import XCTest

/// UI coverage for the **rally video's controls** on the tag sheet (prompt 257, device feedback "video look so small on
/// this page and there are no controls"). Seeded by `-uiTestSeedRacketVideos -uiTestRacketPlayer portrait|landscape`: the
/// match filmed game by game over a synthetic bundled clip (a drawn table and ball, no real footage); game 1's rally 13
/// is untagged, so the timeline's "Tag this rally" opens on it. `TEST_RUNNER_RACKET_SHOTS=<dir>` writes screenshots.
@MainActor
final class RacketRallyVideoUITests: XCTestCase {
    var app: XCUIApplication!

    private func launch(_ variant: String) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketPlayer", variant]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["RACKET_SHOTS"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private var box: XCUIElement { any("racket.rallyVideo.box") }
    private var picture: XCUIElement { any("racket.rallyVideo.picture") }
    private var play: XCUIElement { app.buttons["racket.rallyVideo.play"] }
    private var time: XCUIElement { any("racket.rallyVideo.time") }

    /// History → the seeded session → Your videos → game 1's timeline.
    private func openTimeline() {
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
        tapWhenHittable(app.buttons["racket.videos.mark.0"])
        XCTAssertTrue(app.buttons["racket.tl.tag"].waitForExistence(timeout: 6))
    }

    /// The timeline's "Tag this rally" → the tag sheet on rally 13, its video loaded (the picture shows).
    private func openTagSheet() {
        tapWhenHittable(app.buttons["racket.tl.tag"])
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 6))
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "the video loaded")
        // The box takes the picture's shape once the size is known.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && abs(picture.frame.width - box.frame.width) > 2 { Thread.sleep(forTimeInterval: 0.2) }
    }

    /// "0:03 / 0:10" → (3, 10).
    private func clock(_ el: XCUIElement) -> (now: Int, length: Int) {
        let parts = el.label.components(separatedBy: " / ").map { p in
            p.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        return (parts.first ?? -1, parts.count > 1 ? parts[1] : -1)
    }

    // MARK: Shape

    func testPortraitClipTakesItsOwnShapeAndTheWinnerRowStaysVisible() {
        launch("portrait")
        openTimeline()
        openTagSheet()
        XCTAssertEqual(picture.frame.width, box.frame.width, accuracy: 2, "no side bars: the picture is the box")
        XCTAssertEqual(picture.frame.height, box.frame.height, accuracy: 2)
        XCTAssertGreaterThan(box.frame.height, box.frame.width, "a portrait box for a portrait clip")
        XCTAssertGreaterThan(box.frame.height, 300, "a big picture, not the old 190 pt strip")
        XCTAssertTrue(app.buttons["racket.tag.winner.us"].isHittable, "Who won is on the first screen")
        XCTAssertLessThanOrEqual(app.buttons["racket.tag.winner.us"].frame.maxY, app.windows.firstMatch.frame.maxY - 20)
        for id in ["play", "replay", "speed", "rotate", "expand", "scrub", "earlier", "later"] {
            let el = any("racket.rallyVideo.\(id)")
            XCTAssertTrue(el.exists, id)
            XCTAssertGreaterThanOrEqual(el.frame.height, 44, "\(id) is a 44 pt target")
        }
        shot("tag-video-portrait")
    }

    func testLandscapeClipIsFullWidthSixteenByNine() {
        launch("landscape")
        openTimeline()
        openTagSheet()
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(box.frame.width, window.width - 32, accuracy: 2, "full sheet width")
        XCTAssertEqual(box.frame.width / box.frame.height, 16.0 / 9.0, accuracy: 0.05)
        XCTAssertEqual(picture.frame.width, box.frame.width, accuracy: 2, "no side bars")
        shot("tag-video-landscape")
    }

    // MARK: Controls

    func testTapSpeedScrubAndWiden() {
        launch("portrait")
        openTimeline()
        openTagSheet()
        XCTAssertEqual(play.label, "Pause", "it loops from the start")

        // Tap the picture: pause, with the glyph; tap again: play.
        picture.tap()
        XCTAssertEqual(play.label, "Play")
        XCTAssertTrue(any("racket.rallyVideo.glyph").exists, "a brief centre glyph")
        picture.tap()
        XCTAssertEqual(play.label, "Pause")
        play.tap()
        XCTAssertEqual(play.label, "Play", "the button pauses too")

        // Speed: 1× → 0.5× → 0.25×.
        let speed = app.buttons["racket.rallyVideo.speed"]
        XCTAssertEqual(speed.value as? String, "1×")
        speed.tap()
        XCTAssertEqual(speed.value as? String, "0.5×")
        speed.tap()
        XCTAssertEqual(speed.value as? String, "0.25×")

        // Scrub: drag from the start to near the end; the time follows, and release carries on (slowly) from there.
        let scrub = any("racket.rallyVideo.scrub")
        let length = clock(time).length
        XCTAssertGreaterThan(length, 5)
        scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        let after = clock(time)
        XCTAssertGreaterThanOrEqual(after.now, Int(Double(length) * 0.7), time.label)
        XCTAssertEqual(play.label, "Pause", "release resumes the loop")

        // −3 s / +3 s widen the loop.
        app.buttons["racket.rallyVideo.earlier"].tap()
        XCTAssertEqual(clock(time).length, length + 3, time.label)
        app.buttons["racket.rallyVideo.later"].tap()
        XCTAssertEqual(clock(time).length, length + 6, time.label)
        app.buttons["racket.rallyVideo.replay"].tap()
        XCTAssertEqual(play.label, "Pause")
        XCTAssertLessThanOrEqual(clock(time).now, 1, "Replay starts the loop again")
    }

    func testExpandZoomAndDone() {
        launch("portrait")
        openTimeline()
        openTagSheet()
        app.buttons["racket.rallyVideo.expand"].tap()
        let surface = any("racket.rallyVideo.full.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 4), "full screen")
        XCTAssertTrue(any("racket.rallyVideo.full.scrub").exists)
        XCTAssertTrue(app.buttons["racket.rallyVideo.full.speed"].exists)
        XCTAssertGreaterThan(surface.frame.height, 500, "the clip on the whole screen")
        surface.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(app.buttons["racket.rallyVideo.full.zoom"].waitForExistence(timeout: 3), "zoomed in")
        shot("tag-video-fullscreen")
        app.buttons["racket.rallyVideo.full.zoom"].tap()
        XCTAssertTrue(app.buttons["racket.rallyVideo.full.zoom"].waitForNonExistence(timeout: 3), "zoom reset")
        app.buttons["racket.rallyVideo.full.done"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4), "back on the tag sheet")
        XCTAssertTrue(play.exists)
    }

    func testRotateIsKeptForTheRecording() {
        launch("portrait")
        openTimeline()
        openTagSheet()
        let rotate = app.buttons["racket.rallyVideo.rotate"]
        XCTAssertEqual(rotate.value as? String, "0°")
        rotate.tap()
        XCTAssertEqual(rotate.value as? String, "90°")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && box.frame.width <= box.frame.height { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertGreaterThan(box.frame.width, box.frame.height, "turned: the portrait clip shows wide")
        XCTAssertEqual(picture.frame.width, box.frame.width, accuracy: 2, "still no side bars")
        shot("tag-video-rotated")

        // Closed and opened again: still turned.
        app.buttons["racket.tag.close"].tap()
        XCTAssertTrue(app.buttons["racket.tl.tag"].waitForExistence(timeout: 4))
        openTagSheet()
        XCTAssertEqual(app.buttons["racket.rallyVideo.rotate"].value as? String, "90°", "kept on the recording")
        XCTAssertGreaterThan(box.frame.width, box.frame.height)
    }
}
