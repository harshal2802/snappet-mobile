import XCTest

/// UI coverage for **On the Board** (Kilter Improvement P5): reach the timeline from the Kilter More menu
/// and confirm it renders (the empty state on a fresh store, since a simulator has no BLE board to light a
/// climb on — the live capture + re-light leg is device-pending, MrRobot). Mirrors `KilterHistoryP4Tests`'
/// fixture-import entry pattern (issue #42: the app ships no catalog, so the synthetic
/// `KilterCatalogFixture` is installed via `-uiTestInstallKilterCatalog`).
@MainActor
final class KilterOnTheBoardUITests: XCTestCase {

    private func openKilter() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()

        let card = app.buttons["moduleCard.kilter"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Kilter card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        return app
    }

    /// Open On the Board from the More menu and confirm the screen renders. On a fresh store with no lit
    /// climbs it shows the empty state — the timeline itself appears once a climb is lit on a real board.
    func testOpenOnTheBoardFromMoreMenu() {
        let app = openKilter()

        let more = app.buttons["kilter.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8), "The Kilter More menu should be present")
        more.tap()

        let onTheBoard = app.buttons["kilter.onTheBoard"]
        XCTAssertTrue(onTheBoard.waitForExistence(timeout: 4), "More should offer On the Board")
        onTheBoard.tap()

        XCTAssertTrue(app.navigationBars["On the Board"].waitForExistence(timeout: 6),
                      "The On the Board screen should appear")
    }

    /// The "Recently on the board" rail is absent on a fresh store (nothing lit yet) — it appears once a
    /// climb has been lit on a real board (device-pending). This guards the hidden-until-populated rule.
    func testRecentRailHiddenWhenNothingLit() {
        let app = openKilter()
        // Give the catalog list a beat to load so the root content is fully up.
        XCTAssertTrue(app.buttons["kilter.climbRow"].firstMatch.waitForExistence(timeout: 8),
                      "Catalog should list fixture climbs")
        XCTAssertFalse(app.otherElements["kilter.board.recentRail"].exists,
                       "The recent rail should be hidden until a climb is lit")
    }
}
