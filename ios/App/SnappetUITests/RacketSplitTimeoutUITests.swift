import XCTest

/// Prompt 258 on the user's real match (`-uiTestRacketSplitTimeout`): split and saved some time ago, Game 4, a 3:10
/// break that was really a timeout, Game 5 — both unscored. Play in the split sheet after moving the end handle and
/// after Split here; choosing Timeout joins them into one row in Your videos; the player skips the timeout; back to a
/// break gives two games; the disabled reasons. No Photos video: the player runs its stand-in clock. Screenshots with
/// `RACKET_SHOTS=<dir>` (set through `TEST_RUNNER_RACKET_SHOTS`).
@MainActor
final class RacketSplitTimeoutUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestRacketSplitTimeout", "-uiTestFakeCamera"]
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments += extra
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["RACKET_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 10 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        // A button straddling the bottom edge counts as hittable but its centre is off screen: bring it fully in.
        let bottom = app.windows.firstMatch.frame.maxY - 60
        while (!el.isHittable || el.frame.maxY > bottom) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openYourVideos() {
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
    }

    /// Your videos → Change the split → Fix on part `k`.
    private func fix(_ k: Int) {
        tapWhenHittable(app.buttons["racket.videos.changeSplit"])
        XCTAssertTrue(app.buttons["racket.split.apply"].waitForExistence(timeout: 5), "the saved split reopens")
        tapWhenHittable(app.buttons["racket.split.fix.\(k)"])
        XCTAssertTrue(app.buttons["racket.split.edit.save"].waitForExistence(timeout: 4))
    }

    /// "Playhead 37:02" → seconds.
    private func playhead() -> Int {
        let label = any("racket.split.edit.playhead").label.replacingOccurrences(of: "Playhead ", with: "")
        let p = label.split(separator: ":").compactMap { Int($0) }
        return p.reduce(0) { $0 * 60 + $1 }
    }

    func testPlayInTheSplitSheetAdvancesAfterTheEndHandleAndAfterSplitHere() {
        launch()
        openYourVideos()
        fix(5)   // Game 4, 37:00–45:00
        XCTAssertTrue(any("racket.split.edit.video").exists, "the picture-shaped video box")
        XCTAssertTrue(any("racket.split.edit.speed").exists)
        app.buttons["racket.split.edit.end.-10"].tap()     // the playhead goes to the end (44:50)
        XCTAssertEqual(playhead(), 44 * 60 + 50)
        app.buttons["racket.split.edit.play"].tap()
        Thread.sleep(forTimeInterval: 2.5)
        let a = playhead()
        XCTAssertTrue(a > 37 * 60 && a < 37 * 60 + 10, "Play starts the part from its start and advances: \(a)")
        shot("01-play-after-end-handle")
        Thread.sleep(forTimeInterval: 6)
        app.buttons["racket.split.edit.play"].tap()      // pause inside the part
        let cut = playhead()
        XCTAssertGreaterThan(cut, 37 * 60 + 5)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(playhead(), cut, "Pause holds the playhead")
        let splitHere = app.buttons["racket.split.edit.splitHere"]
        // Scroll by dragging the "Playhead" line (a swipe from the middle of the sheet would drag the range strip
        // and move the playhead), until the button is clear of the bottom edge.
        let handle = any("racket.split.edit.playhead").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        handle.press(forDuration: 0.05, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: -260)))
        XCTAssertLessThan(splitHere.frame.maxY, app.windows.firstMatch.frame.maxY - 40, "Split here is on screen")
        splitHere.tap()
        let range = any("racket.split.edit.range").label
        XCTAssertTrue(range.hasPrefix("37:00–") && !range.hasSuffix("44:50"), "the sheet stays on the first half, now shorter: \(range)")
        app.buttons["racket.split.edit.play"].tap()
        Thread.sleep(forTimeInterval: 2.5)
        let b = playhead()
        XCTAssertTrue(b > 37 * 60 && b < cut, "the first half plays from its start: \(b) (cut \(cut)) range=\(any("racket.split.edit.range").label) playLabel=\(app.buttons["racket.split.edit.play"].label)")
        shot("02-play-after-split-here")
    }

    func testTimeoutJoinsGamesFourAndFiveSkipsWhenPlayingAndUndoes() {
        launch()
        openYourVideos()
        XCTAssertTrue(any("racket.videos.line.5").exists, "six games before")
        shot("03-your-videos-before")

        // The disabled reasons: Timeout on the break before Game 4 (warmup … game 3, break, game 4 is fine); on Game 1
        // (first game, warmup before it) the chip is off and says why.
        fix(1)
        XCTAssertFalse(app.buttons["racket.split.edit.kind.timeout"].isEnabled)
        XCTAssertEqual(any("racket.split.edit.timeoutReason").label, "A timeout sits between two halves of the same game.")
        shot("04-timeout-disabled-reason")
        app.buttons["Cancel"].tap()

        // The break between Game 4 and Game 5 → Timeout.
        tapWhenHittable(app.buttons["racket.split.fix.6"])
        XCTAssertTrue(app.buttons["racket.split.edit.kind.timeout"].waitForExistence(timeout: 4))
        app.buttons["racket.split.edit.kind.timeout"].tap()
        XCTAssertEqual(any("racket.split.edit.title").label, "Timeout")
        XCTAssertFalse(app.buttons["racket.split.edit.splitHere"].isEnabled, "a timeout can't be split")
        XCTAssertFalse(app.buttons["racket.split.edit.merge"].isEnabled)
        XCTAssertTrue(any("racket.split.edit.splitNote").label.contains("A timeout can’t be split"), any("racket.split.edit.splitNote").label)
        shot("05-timeout-chosen")
        app.buttons["racket.split.edit.save"].tap()
        XCTAssertTrue(app.buttons["racket.split.part.7"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.split.part.6"].label.contains("Timeout"), app.buttons["racket.split.part.6"].label)
        XCTAssertTrue(app.buttons["racket.split.part.6"].label.contains("3:10, skipped"), app.buttons["racket.split.part.6"].label)
        XCTAssertTrue(app.buttons["racket.split.part.7"].label.contains("Game 4, continued"), app.buttons["racket.split.part.7"].label)
        XCTAssertTrue(app.buttons["racket.split.part.8"].label.contains("Game 5"), app.buttons["racket.split.part.8"].label)
        shot("06-review-with-timeout")
        tapWhenHittable(app.buttons["racket.split.apply"])
        // On a phone the tap can land while the list is still settling after the scroll and be swallowed: once more.
        if !any("racket.assign.row.4").waitForExistence(timeout: 5), app.buttons["racket.split.apply"].exists {
            app.buttons["racket.split.apply"].tap()
        }
        XCTAssertTrue(any("racket.assign.row.4").waitForExistence(timeout: 5))
        XCTAssertFalse(any("racket.assign.row.5").exists, "five games")
        XCTAssertTrue(any("racket.assign.row.3").label.contains("37:00–45:00 + 48:10–55:00"), any("racket.assign.row.3").label)
        shot("07-assign")
        app.buttons["racket.assign.save"].tap()
        tapWhenHittable(app.buttons["racket.splitDone.done"])

        // Your videos: one row for Game 4, its length played time.
        XCTAssertTrue(any("racket.videos.line.3").waitForExistence(timeout: 5))
        XCTAssertFalse(any("racket.videos.line.5").exists, "one row per game")
        XCTAssertEqual(any("racket.videos.line.3").label, "14:50 · 1 timeout skipped")
        for _ in 0..<5 where !any("racket.videos.line.3").isHittable { app.swipeUp(velocity: .slow) }
        shot("08-your-videos-joined")

        // Back to a break: two games again.
        fix(6)
        app.buttons["racket.split.edit.kind.breakTime"].tap()
        app.buttons["racket.split.edit.save"].tap()
        tapWhenHittable(app.buttons["racket.split.apply"])
        app.buttons["racket.assign.save"].tap()
        tapWhenHittable(app.buttons["racket.splitDone.done"])
        XCTAssertTrue(any("racket.videos.line.5").waitForExistence(timeout: 5), "six games again")
        XCTAssertEqual(any("racket.videos.line.4").label, "1–1? · 6:50", "Game 5 is back, its tags suggest a score")
        shot("09-your-videos-undone")
    }

    func testThePlayerSkipsTheTimeout() {
        // Joined already (as saved after the test above), opened at 44:55, five seconds before the timeout.
        launch(["-uiTestRacketSplitTimeoutJoined", "-uiTestRacketPlayerStart", "2695"])
        openYourVideos()
        XCTAssertEqual(any("racket.videos.line.3").label, "14:50 · 1 timeout skipped")
        tapWhenHittable(app.buttons["racket.videos.play.3"])
        let surface = any("racket.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 9)
        let v = surface.value as? String ?? ""
        // Without the skip it would sit at 08:00 (the timeout reads as its start) for 3:10.
        XCTAssertTrue(v.hasSuffix("/ 14:50"), v)
        let played = v.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertTrue(["08:02", "08:03", "08:04", "08:05", "08:06", "08:07", "08:08", "08:09"].contains(played), "played on past the timeout: \(v)")
        shot("10-player-skipped-timeout")
    }
}
