import XCTest

/// Prompt 260 on the user's real case (`-uiTestRacketEditMatch`): a stray 9–11 logged five minutes before the
/// recording, then the recording's three games (9–11 each), split and saved. The recap reads "L 0–4". Edit match →
/// remove the stray game → Save gives three games and 0–3, and Your videos still plays Games 1–3 with their scores;
/// Cancel leaves everything as it was; removing a game with video asks what happens to its video; a move that would
/// contradict the video order is disabled with its reason. Screenshots with `RACKET_SHOTS=<dir>` (set through
/// `TEST_RUNNER_RACKET_SHOTS`).
@MainActor
final class RacketEditMatchUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestRacketEditMatch", "-uiTestFakeCamera"]
        app.launchOnTestStore()
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
        let bottom = app.windows.firstMatch.frame.maxY - 60
        while (!el.isHittable || el.frame.maxY > bottom) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    /// History → the seeded session (its detail, with the racket recap).
    private func openSession() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded session")
        row.tap()
        XCTAssertTrue(any("racket.recap.match").waitForExistence(timeout: 6))
    }

    private var recapMatch: String { any("racket.recap.match").label }

    private func openEditor() {
        tapWhenHittable(app.buttons["racket.recap.editMatch"])
        XCTAssertTrue(any("racket.editMatch.result").waitForExistence(timeout: 5), "the editor opens")
    }

    func testRemovingTheStrayGameGivesThreeGamesZeroThreeAndVideosStillPlay() {
        openSession()
        XCTAssertTrue(recapMatch.contains("L 0–4"), recapMatch)
        shot("01-recap-before")
        openEditor()
        XCTAssertEqual(any("racket.editMatch.result").label, "L 0–4 · 4 games")
        XCTAssertTrue(any("racket.editMatch.game.0").label.contains("No video"), any("racket.editMatch.game.0").label)
        XCTAssertTrue(any("racket.editMatch.game.1").label.contains("Video 0:00–4:30"), any("racket.editMatch.game.1").label)
        shot("02-editor")
        any("racket.editMatch.game.0").tap()
        XCTAssertTrue(app.buttons["racket.editMatch.g.remove"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.editMatch.g.video").label, "No video")
        shot("03-stray-game")
        tapWhenHittable(app.buttons["racket.editMatch.g.remove"])
        // No video: no question; back on the list with three games.
        XCTAssertTrue(any("racket.editMatch.result").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.editMatch.result").label, "L 0–3 · 3 games")
        XCTAssertFalse(any("racket.editMatch.game.3").exists)
        shot("04-after-remove")
        app.buttons["racket.editMatch.save"].tap()
        XCTAssertTrue(any("racket.recap.match").waitForExistence(timeout: 5))
        let saved = NSPredicate(format: "label CONTAINS 'L 0–3'")
        expectation(for: saved, evaluatedWith: any("racket.recap.match"))
        waitForExpectations(timeout: 5)
        XCTAssertEqual(recapMatch.components(separatedBy: "9–11").count - 1, 3, "three games: \(recapMatch)")
        shot("05-recap-after")

        tapWhenHittable(app.buttons["racket.recap.videos"])
        XCTAssertTrue(any("racket.videos.line.0").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.videos.line.0").label, "9–11 · 4:30")
        XCTAssertEqual(any("racket.videos.line.1").label, "9–11 · 4:30")
        XCTAssertEqual(any("racket.videos.line.2").label, "9–11 · 3:31")
        XCTAssertFalse(any("racket.videos.line.3").exists, "three games")
        XCTAssertEqual(any("racket.videos.tags.2").label, "3 marked by you", "tags intact")
        // The second match's rows have their own ids.
        XCTAssertTrue(any("racket.videos.line.m1.0").exists, "the second match's first row")
        XCTAssertEqual(app.buttons.matching(identifier: "racket.videos.play.0").count, 1, "one Play per id")
        shot("06-your-videos")
        tapWhenHittable(app.buttons["racket.videos.play.0"])
        let surface = any("racket.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 8), "Game 1 plays")
        XCTAssertTrue((surface.value as? String ?? "").hasSuffix("4:30"), surface.value as? String ?? "")
        shot("07-game-1-plays")
    }

    func testCancelLeavesEverythingAsItWas() {
        openSession()
        openEditor()
        any("racket.editMatch.game.0").tap()
        tapWhenHittable(app.buttons["racket.editMatch.g.remove"])
        XCTAssertTrue(any("racket.editMatch.result").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.editMatch.result").label, "L 0–3 · 3 games")
        app.buttons["racket.editMatch.cancel"].tap()
        XCTAssertTrue(any("racket.recap.match").waitForExistence(timeout: 5))
        XCTAssertTrue(recapMatch.contains("L 0–4"), "Cancel keeps four games: \(recapMatch)")
        shot("08-after-cancel")
    }

    func testRemovingAGameWithVideoAsksAndADisabledMoveSaysWhy() {
        openSession()
        openEditor()
        any("racket.editMatch.game.3").tap()
        XCTAssertTrue(app.buttons["racket.editMatch.g.earlier"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["racket.editMatch.g.earlier"].isEnabled, "Game 3 and Game 4 both have video")
        XCTAssertEqual(any("racket.editMatch.g.moveReason").label,
                       "Both games have video, so they keep the order of their video. Change the split to fix the video.")
        shot("09-move-disabled-reason")
        tapWhenHittable(app.buttons["racket.editMatch.g.remove"])
        let extra = app.buttons["Keep as an extra game (not counted in the match)"]
        XCTAssertTrue(extra.waitForExistence(timeout: 4), "the choice sheet")
        XCTAssertTrue(app.buttons["Mark as not play"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '3 tagged rallies stop counting'")).firstMatch.exists
                      || app.otherElements.containing(NSPredicate(format: "label CONTAINS '3 tagged rallies'")).firstMatch.exists,
                      "the sheet says how many tags stop counting")
        shot("10-remove-video-choice")
        // The dialog's Cancel is a tap outside it on iOS 26 (no Cancel row is drawn).
        let cancel = app.buttons["racket.editMatch.removeChoice.cancel"]
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
        XCTAssertTrue(extra.waitForNonExistence(timeout: 4), "the choice sheet closes")
        XCTAssertTrue(any("racket.editMatch.g.video").label.hasPrefix("Video"), "the game keeps its video")
        XCTAssertTrue(app.buttons["racket.editMatch.g.remove"].waitForExistence(timeout: 4), "Cancel keeps the game")
    }
}
