import XCTest

/// Festival mini-app walkthrough (festival prompt 02): the catalog empty state + browse sheet on a
/// fresh store, then — via the now-anchored `-uiTestSeedFestivalLineup` lineup — the day schedule
/// (NOW pill, ★ stars, clash marks) and the "I'm here" live sheet on the dance-session spine.
/// Identifiers come from `festival.*`; interactive children (stars, GET, switch) carry their OWN
/// ids — a container identifier flattens child buttons out of the XCUITest tree (highlights-P5).
@MainActor final class FestivalUITests: XCTestCase {

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Opens the Festival mini-app from the App Library (Lifestyle section).
    private func openFestival(_ app: XCUIApplication) {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.festival"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Festival card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    // MARK: - Flow A · catalog (frames 1–3)

    func testEmptyStateLeadsWithDownloadAndOpensTheBrowseSheet() {
        let app = launch(["-uiTestFreshStore"])
        openFestival(app)

        // 1 — the opt-in empty state: download leads, import beneath, data-posture card.
        let browse = app.buttons["festival.catalog.browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 6), "fresh store should show the empty state")
        XCTAssertTrue(app.buttons["festival.catalog.import"].exists,
                      "the power-user file import should sit beneath the download CTA")
        snap("festival-empty")

        // 2 — the hosted-catalog browse sheet opens with its own stack. Its list content depends
        // on the network, so assert only the sheet chrome (deterministic offline AND online).
        browse.tap()
        XCTAssertTrue(app.navigationBars["Snappet Lineups"].waitForExistence(timeout: 6),
                      "the browse sheet should present")
        snap("festival-browse")
        app.buttons["festival.browse.cancel"].tap()
        XCTAssertTrue(app.buttons["festival.catalog.browse"].waitForExistence(timeout: 6),
                      "cancel should return to the empty state")
    }

    // MARK: - Flow B · the weekend (frames 4–5)

    func testScheduleStarsClashAndTheLiveSheet() {
        let app = launch([FestivalSeed.argument])
        openFestival(app)

        // 1 — the seeded lineup lists; push its schedule.
        let lineup = app.buttons["festival.lineup.snappet-test-festival"]
        XCTAssertTrue(lineup.waitForExistence(timeout: 6), "the seeded lineup should list")
        lineup.tap()

        // 2 — day schedule: stage-grouped rows, the anchor set glowing NOW.
        let nowBadge = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'NOW'")).firstMatch
        XCTAssertTrue(nowBadge.waitForExistence(timeout: 6), "the live set should carry a NOW pill")
        XCTAssertTrue(app.staticTexts["Fred Midnight"].exists)
        XCTAssertTrue(app.staticTexts["PYRAMID STAGE"].exists, "rows group by stage")
        snap("festival-schedule")

        // 3 — star the overlapping pair → both rows flag the clash; unstar clears it.
        app.buttons["festival.star.Overtone"].tap()
        app.buttons["festival.star.Electric Fern"].tap()
        XCTAssertTrue(app.staticTexts["festival.clash.Overtone"].waitForExistence(timeout: 4),
                      "starring two overlapping sets should flag a clash")
        XCTAssertTrue(app.staticTexts["festival.clash.Electric Fern"].exists)
        snap("festival-clash")
        app.buttons["festival.star.Electric Fern"].tap()
        XCTAssertFalse(app.staticTexts["festival.clash.Overtone"].waitForExistence(timeout: 2),
                       "unstarring one side should clear the clash")

        // 4 — "I'm here" starts the dance-session spine and opens the live sheet.
        let imHere = app.buttons["festival.imHere"]
        XCTAssertTrue(imHere.waitForExistence(timeout: 4), "a live set should offer I'm here")
        imHere.tap()
        XCTAssertTrue(app.staticTexts["festival.live.artist"].waitForExistence(timeout: 6),
                      "the live sheet should open on the claimed artist")
        XCTAssertTrue(app.buttons["festival.live.record"].exists, "the record-clip control rides along")
        snap("festival-live")

        // 5 — switch to the up-next set via the dialog; the sheet re-anchors in place.
        app.buttons["festival.live.switch"].tap()
        let overtone = app.buttons["Overtone · West Holts (up next)"]
        XCTAssertTrue(overtone.waitForExistence(timeout: 4), "the switcher should offer up next")
        overtone.tap()
        let reanchored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Overtone'"),
            object: app.staticTexts["festival.live.artist"])
        XCTAssertEqual(XCTWaiter().wait(for: [reanchored], timeout: 6), .completed,
                       "switching should re-anchor the sheet on Overtone")
        snap("festival-switched")

        // 6 — end the night: the sheet closes and the CTA returns to I'm here for the live set.
        let end = app.buttons["festival.live.end"]
        if !end.isHittable {
            // Below the medium-detent fold — scrolling up expands the sheet to .large first.
            app.swipeUp()
        }
        end.tap()
        XCTAssertTrue(imHere.waitForExistence(timeout: 6), "ending should surface the CTA again")
        XCTAssertTrue(imHere.label.contains("I'm here"),
                      "after ending, the claim CTA should reset from On the floor")
    }
}

/// Mirror of the app-side seed argument (the UI-test target can't import the app module's enum).
private enum FestivalSeed {
    static let argument = "-uiTestSeedFestivalLineup"
}
