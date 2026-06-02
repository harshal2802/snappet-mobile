import XCTest

/// UI coverage for the Kilter mini-app's Phase-1 flow: open the catalog from the App Library, open a
/// climb, log a send, and confirm it lands in History. Mirrors `TipUITests`' entry pattern (open the
/// App Library and tap the module card). The bundled catalog ships in the app, so it's available even
/// with the fresh in-memory store (which only resets user data).
final class KilterUITests: XCTestCase {

    /// Launch into the App Library and open the Kilter mini-app.
    private func openKilter() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore"]
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

    /// Browse → open a climb → log a send → confirm it appears in History.
    func testLoggingASendAppearsInHistory() {
        let app = openKilter()

        let firstRow = app.buttons["kilter.climbRow"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8), "Catalog should list climbs from the bundle")
        firstRow.tap()

        let send = app.buttons["kilter.log.sent"]
        XCTAssertTrue(send.waitForExistence(timeout: 6), "Detail screen should offer a Sent log button")
        send.tap()

        // Confirmation appears inline on a successful log.
        XCTAssertTrue(app.staticTexts["kilter.logConfirmation"].waitForExistence(timeout: 4),
                      "Logging should confirm on screen")

        app.buttons["kilter.history"].tap()
        let row = app.descendants(matching: .any)["kilter.historyRow"]
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 6),
                      "A history row should appear after logging a send")
    }

    /// Saving a climb makes it show under the Saved filter.
    func testSavingAClimbShowsUnderSavedFilter() {
        let app = openKilter()

        let firstRow = app.buttons["kilter.climbRow"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))
        firstRow.tap()

        let favorite = app.buttons["kilter.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 6), "Detail screen should offer a Save toggle")
        favorite.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to the catalog

        app.buttons["kilter.savedToggle"].tap()
        let row = app.buttons["kilter.climbRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "Saved filter should show the climb we just starred")
    }
}
