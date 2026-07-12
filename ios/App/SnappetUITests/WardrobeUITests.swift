import XCTest

/// Wardrobe mini-app walkthrough (wardrobe prompts 01+02): open from the App Library,
/// seed the sample closet, then ride the STYLIST-FIRST HOME — For You carousel → board
/// → save, closet preview → item detail, "See all" → the segmented sections screen.
/// Identifiers come from `wardrobe.*`; the sample closet keeps the flow device-free.
final class WardrobeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Opens the Wardrobe mini-app from the App Library (Lifestyle section).
    private func openWardrobe() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.wardrobe"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Wardrobe card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    func testHomeForYouBoardSectionsAndOutfits() {
        openWardrobe()

        // 1 — empty state → seed the sample closet.
        let sample = app.buttons["wardrobe.empty.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 6), "fresh store should show the empty state")
        snap("wardrobe-empty")
        sample.tap()

        // 2 — the stylist-first home: For You carousel + closet preview, ONE bottom bar.
        // The preview shows the 4 NEWEST pieces — in the fixture that's the joggers,
        // tee, beanie and chinos (the flannel is older and lives behind "See all").
        let forYouCard = app.buttons["wardrobe.forYou.card"].firstMatch
        XCTAssertTrue(forYouCard.waitForExistence(timeout: 6), "home should lead with For You cards")
        XCTAssertTrue(app.staticTexts["Grey joggers"].waitForExistence(timeout: 4),
                      "home should preview the newest closet items")
        snap("wardrobe-home")

        // 3 — item detail from the home preview.
        app.staticTexts["Grey joggers"].firstMatch.tap()
        XCTAssertTrue(app.buttons["wardrobe.item.style"].waitForExistence(timeout: 6),
                      "item detail should offer Style this")
        snap("wardrobe-item")
        app.navigationBars.buttons.firstMatch.tap()   // back home

        // 4 — For You card → flat-lay board → save.
        app.buttons["wardrobe.forYou.card"].firstMatch.tap()
        let save = app.buttons["wardrobe.board.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6), "the flat-lay board should open")
        snap("wardrobe-board")
        save.tap()
        app.navigationBars.buttons.firstMatch.tap()   // back home

        // 5 — "See all" → the segmented sections screen (Closet first).
        app.buttons["wardrobe.home.seeAllCloset"].tap()
        let picker = app.segmentedControls["wardrobe.sections.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6), "sections screen should show the segmented control")
        snap("wardrobe-sections-closet")

        // 6 — quick-jump to Outfits without popping; the saved outfit is there.
        picker.buttons["Outfits"].tap()
        XCTAssertTrue(app.buttons["wardrobe.outfits.wearAgain"].firstMatch.waitForExistence(timeout: 6),
                      "the saved outfit should appear under Outfits")
        snap("wardrobe-sections-outfits")
    }
}
