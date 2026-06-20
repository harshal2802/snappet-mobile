import XCTest

/// UI coverage for the Kilter analytics dashboard (Kilter Improvement P3): log a send, open Stats from
/// the catalog's More menu, confirm the segmented grade pyramid renders, tap a grade to filter the
/// in-page ascent log, then open a trend tile and confirm its detail screen (with range chips). Also
/// confirms History still loads after the inline-summary/pyramid math was removed.
///
/// Mirrors `KilterUITests`' fixture-import entry pattern (issue #42: the app ships no catalog, so the
/// synthetic `KilterCatalogFixture` is installed via `-uiTestInstallKilterCatalog`).
@MainActor
final class KilterStatsTests: XCTestCase {

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

    /// Log one send so the dashboard has data to render.
    private func logASend(_ app: XCUIApplication) {
        let firstRow = app.buttons["kilter.climbRow"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8), "Catalog should list fixture climbs")
        firstRow.tap()
        let send = app.buttons["kilter.log.sent"]
        XCTAssertTrue(send.waitForExistence(timeout: 6), "Detail should offer a Sent log button")
        send.tap()
        XCTAssertTrue(app.staticTexts["kilter.logConfirmation"].waitForExistence(timeout: 4),
                      "Logging should confirm on screen")
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to the catalog
    }

    /// Open Stats from the catalog's More menu.
    private func openStats(_ app: XCUIApplication) {
        let more = app.buttons["kilter.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 6), "Catalog should have a More menu")
        more.tap()
        let stats = app.buttons["kilter.stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 4), "More menu should list Stats")
        stats.tap()
    }

    func testDashboardPyramidTrendAndFilter() {
        let app = openKilter()
        logASend(app)
        openStats(app)

        // The hero + segmented pyramid render from the all-time aggregate.
        XCTAssertTrue(app.descendants(matching: .any)["kilter.stats.hero"].waitForExistence(timeout: 8),
                      "The Climbing Level hero should render")
        XCTAssertTrue(app.descendants(matching: .any)["kilter.stats.pyramid"].waitForExistence(timeout: 6),
                      "The segmented grade pyramid should render")

        // Tap a grade bar → the in-page filtered ascent log appears.
        let bar = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'kilter.stats.pyramidBar.'")).firstMatch
        if bar.waitForExistence(timeout: 4) {
            bar.tap()
            XCTAssertTrue(app.descendants(matching: .any)["kilter.stats.ascentLog"].waitForExistence(timeout: 4),
                          "Tapping a grade should reveal the filtered ascent log")
        }

        // Tap the sends-per-week tile → its trend screen with range chips.
        let volumeTile = app.buttons["kilter.stats.tile.volume"]
        XCTAssertTrue(volumeTile.waitForExistence(timeout: 4), "The Sends/week doorway tile should exist")
        volumeTile.tap()
        XCTAssertTrue(app.buttons["kilter.trend.range.months3"].waitForExistence(timeout: 6),
                      "The volume trend screen should offer range chips")
    }

    /// History still loads (sessions + ascents) after the inline summary/pyramid math was removed, and
    /// links to the dashboard.
    func testHistoryStillLoadsAndLinksToStats() {
        let app = openKilter()
        logASend(app)

        app.buttons["kilter.history"].tap()
        // Stats link is at the top of History (check + capture before any scrolling).
        let link = app.buttons["kilter.history.statsLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 6), "History should link to the stats dashboard")
        // History still surfaces the logged climb (session card on screen, or ascent row below).
        XCTAssertTrue(app.hasLoggedHistoryRow(), "History should still show logged climbs")
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["kilter.stats.hero"].waitForExistence(timeout: 6),
                      "The stats link should open the dashboard")
    }
}
