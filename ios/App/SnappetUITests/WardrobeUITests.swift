import XCTest

/// Wardrobe mini-app walkthrough (wardrobe prompt 01): open from the App Library, seed
/// the sample closet (the no-Photos fixture path), browse into an item, ride For You
/// into a flat-lay board, save it, and find it under Outfits. Identifiers come from
/// `wardrobe.*` on the views; the sample closet keeps the whole flow device-free.
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

    func testSampleClosetForYouBoardAndOutfits() {
        openWardrobe()

        // 1 — empty state → seed the sample closet.
        let sample = app.buttons["wardrobe.empty.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 6), "fresh store should show the empty state")
        snap("wardrobe-empty")
        sample.tap()

        // 2 — the closet grid appears with the seeded items.
        let flannel = app.staticTexts["Navy flannel shirt"]
        XCTAssertTrue(flannel.waitForExistence(timeout: 6), "sample closet should render in the grid")
        snap("wardrobe-closet")

        // 3 — item detail: stats + actions.
        flannel.firstMatch.tap()
        XCTAssertTrue(app.buttons["wardrobe.item.style"].waitForExistence(timeout: 6),
                      "item detail should offer Style this")
        snap("wardrobe-item")
        app.navigationBars.buttons.firstMatch.tap()   // back to the closet

        // 4 — For You: suggestion cards composed from the sample closet.
        app.buttons["wardrobe.tab.forYou"].tap()
        let forYouCard = app.buttons["wardrobe.forYou.card"].firstMatch
        XCTAssertTrue(forYouCard.waitForExistence(timeout: 6), "For You should suggest outfits")
        snap("wardrobe-foryou")

        // 5 — open the board and save the outfit.
        forYouCard.tap()
        let save = app.buttons["wardrobe.board.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6), "the flat-lay board should open")
        snap("wardrobe-board")
        save.tap()
        app.navigationBars.buttons.firstMatch.tap()   // back to For You

        // 6 — the saved outfit shows up under Outfits.
        app.buttons["wardrobe.tab.outfits"].tap()
        XCTAssertTrue(app.buttons["wardrobe.outfits.wearAgain"].firstMatch.waitForExistence(timeout: 6),
                      "the saved outfit should appear in history")
        snap("wardrobe-outfits")
    }
}
