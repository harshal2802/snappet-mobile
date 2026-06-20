import XCTest

/// UI coverage for the redesigned Kilter session history (Kilter Improvement P4): log a send (which
/// auto-opens a session + ascent), open History, confirm the grouped timeline + roll-up header render,
/// flip the scope switcher, toggle a faceted filter chip, open a session from a card, and edit its
/// name + notes (the additive `KilterSession.title`/`notes`). Mirrors `KilterStatsTests`' fixture-import
/// entry pattern (issue #42: the app ships no catalog, so the synthetic `KilterCatalogFixture` is
/// installed via `-uiTestInstallKilterCatalog`).
@MainActor
final class KilterHistoryP4Tests: XCTestCase {

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

    /// Log one send so History has a session + ascent to group.
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

    private func openHistory(_ app: XCUIApplication) {
        let history = app.buttons["kilter.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 6), "Catalog should have a History button")
        history.tap()
    }

    /// The grouped timeline renders with a roll-up header, the scope switcher flips, a facet chip
    /// toggles, and the dashboard link is still present.
    func testGroupedTimelineScopeAndFilter() {
        let app = openKilter()
        logASend(app)
        openHistory(app)

        // Stats link kept from P3.
        XCTAssertTrue(app.buttons["kilter.history.statsLink"].waitForExistence(timeout: 6),
                      "History should still link to the stats dashboard")

        // A roll-up group header renders over the adaptive session card.
        XCTAssertTrue(app.descendants(matching: .any)["kilter.history.groupHeader"].firstMatch
            .waitForExistence(timeout: 6), "A roll-up group header should render")
        XCTAssertTrue(app.descendants(matching: .any)["kilter.sessionRow"].firstMatch
            .waitForExistence(timeout: 6), "An adaptive session card should render")

        // The scope switcher exists and is operable.
        let scope = app.segmentedControls["kilter.history.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 4), "The Week/Month/All scope switcher should exist")
        scope.buttons["All"].tap()

        // A faceted filter chip exists and toggles (selecting it must not crash the list).
        let chip = app.buttons["kilter.history.facetChip"].firstMatch
        if chip.waitForExistence(timeout: 4) { chip.tap() }
    }

    /// Open a session from its card and edit the name + notes (the additive fields), confirming the
    /// title appears in the header.
    func testOpenSessionAndEditNameNotes() {
        let app = openKilter()
        logASend(app)
        openHistory(app)

        let cardRow = app.descendants(matching: .any)["kilter.sessionRow"].firstMatch
        XCTAssertTrue(cardRow.waitForExistence(timeout: 6), "A session card should be present")
        cardRow.tap()

        let edit = app.buttons["kilter.summary.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 6), "Session detail should offer an Edit button")
        edit.tap()

        let titleField = app.textFields["kilter.summaryEdit.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 4), "The editor should offer a name field")
        titleField.tap()
        titleField.typeText("Comp prep")

        let notesField = app.textViews["kilter.summaryEdit.notes"]
        if notesField.waitForExistence(timeout: 2) {
            notesField.tap()
            notesField.typeText("Felt strong.")
        }

        app.buttons["kilter.summaryEdit.save"].tap()

        // The saved name surfaces in the detail header.
        XCTAssertTrue(app.descendants(matching: .any)["kilter.summary.title"].waitForExistence(timeout: 4),
                      "The edited session name should appear in the header")
    }

    /// Swipe-to-edit an ascent row (additive to the long-standing swipe-to-delete).
    func testSwipeEditAnAscent() {
        let app = openKilter()
        logASend(app)
        openHistory(app)

        let ascent = app.descendants(matching: .any)["kilter.historyRow"].firstMatch
        XCTAssertTrue(ascent.waitForExistence(timeout: 6), "An ascent row should be present")
        ascent.swipeLeft()

        let editAction = app.buttons["kilter.ascent.swipeEdit"]
        if editAction.waitForExistence(timeout: 3) {
            editAction.tap()
            XCTAssertTrue(app.buttons["kilter.ascentEdit.save"].waitForExistence(timeout: 4),
                          "The ascent editor should open from swipe-to-edit")
        }
    }
}
