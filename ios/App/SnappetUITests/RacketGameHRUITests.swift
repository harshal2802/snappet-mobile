import XCTest

/// The game heart-rate sheet + HRV (2026-10-26). Seeded by `-uiTestSeedRacketHR`: a finished "City Open" match vs
/// Alex Chen with a chest-strap series (bpm + beat-to-beat RR), so per-game HRV and session HRV are present.
@MainActor
final class RacketGameHRUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketHR"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTapAGameForItsHeartRateAndHRV() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'City Open'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded match session")
        row.tap()

        // Session HRV in the Heart rate section (chest strap ⇒ RR present).
        let toggle = any("hrSummary.toggle")
        // On a tall recap the toggle can sit under the tab bar, where a tap lands on a tab: bring it clear first.
        let clear = app.windows.firstMatch.frame.maxY - 140
        for _ in 0..<5 where !toggle.waitForExistence(timeout: 2) || toggle.frame.maxY > clear { app.swipeUp(velocity: .slow) }
        if toggle.exists { toggle.tap() }
        // Below the fold on a tall recap (the list builds rows as they come near the screen).
        for _ in 0..<4 where !any("sessionHRV").waitForExistence(timeout: 2) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(any("sessionHRV").waitForExistence(timeout: 4), "session HRV shows with a chest strap")
        snap("01-session-hrv")

        // A game tile opens the game sheet.
        let tile = any("racket.game.openHR")
        for _ in 0..<6 where !tile.isHittable {
            if tile.exists && tile.frame.minY < 120 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(tile.waitForExistence(timeout: 4))
        tile.tap()
        XCTAssertTrue(any("racket.gameHR.chart").waitForExistence(timeout: 5), "the game's heart-rate chart")
        XCTAssertTrue(any("racket.gameHR.hrv").exists, "per-game HRV with a chest strap")
        snap("02-game-1")

        // Swipe to game 2: the comparison line against game 1 appears.
        app.swipeLeft()
        XCTAssertTrue(any("racket.gameHR.compare").waitForExistence(timeout: 4), "game 2 compares with game 1")
        XCTAssertTrue(any("racket.gameHR.compare").label.contains("vs game 1"), any("racket.gameHR.compare").label)
        snap("03-game-2")
        app.buttons["racket.gameHR.done"].tap()
        XCTAssertTrue(any("racket.gameHR.chart").waitForNonExistence(timeout: 4))
    }
}
