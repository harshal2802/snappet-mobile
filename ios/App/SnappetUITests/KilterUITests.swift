import XCTest

/// UI coverage for the Kilter mini-app's Phase-1 flow: open the catalog from the App Library, open a
/// climb, log a send, and confirm it lands in History. Mirrors `TipUITests`' entry pattern.
///
/// Issue #42: the app no longer ships a catalog, so the browse tests launch with
/// `-uiTestInstallKilterCatalog`, which installs the **synthetic** test fixture
/// (`KilterCatalogFixture`, zero Aurora data) onto the device before the module opens — standing in for
/// a real user import. A separate test launches *without* that arg and asserts the opt-in sync screen.
final class KilterUITests: XCTestCase {

    /// Launch into the App Library and open the Kilter mini-app. With `installCatalog` the synthetic
    /// fixture is installed first (so there are climbs to browse); without it, the module comes up in
    /// its empty / opt-in state.
    private func openKilter(installCatalog: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore"]
        if installCatalog { app.launchArguments += ["-uiTestInstallKilterCatalog"] }
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

    /// With no catalog installed, the module shows the opt-in sync screen (not a crash, not an empty
    /// list) — the `KilterCatalog.isAvailable == false` path, offering BOTH install paths
    /// (Download leads since #75, mirroring Android #94's assertion of both buttons).
    func testEmptyStateShowsCatalogSyncScreen() {
        let app = openKilter(installCatalog: false)
        XCTAssertTrue(app.buttons["kilter.catalog.sync"].waitForExistence(timeout: 8),
                      "Without a catalog, the opt-in screen should lead with Download")
        XCTAssertTrue(app.buttons["kilter.catalog.import"].exists,
                      "…with file import as the secondary path")
        // No climbs are listed in the empty state.
        XCTAssertFalse(app.buttons["kilter.climbRow"].firstMatch.exists)
    }

    /// Browse (against the imported fixture) → open a climb → log a send → confirm it appears in History.
    func testLoggingASendAppearsInHistory() {
        let app = openKilter()

        let firstRow = app.buttons["kilter.climbRow"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8), "Catalog should list climbs from the fixture")
        firstRow.tap()

        let send = app.buttons["kilter.log.sent"]
        XCTAssertTrue(send.waitForExistence(timeout: 6), "Detail screen should offer a Sent log button")
        send.tap()

        // Confirmation appears inline on a successful log.
        XCTAssertTrue(app.staticTexts["kilter.logConfirmation"].waitForExistence(timeout: 4),
                      "Logging should confirm on screen")

        // History lives on the catalog toolbar, so step back out of the climb detail first.
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
