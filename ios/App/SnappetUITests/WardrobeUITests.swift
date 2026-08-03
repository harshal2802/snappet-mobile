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

    /// Multi-photo surfaces (wardrobe prompt 04). The simulator has no camera and no Photos, so
    /// this covers what IS reachable there: the ··· menu carries a photo count, "Manage photos"
    /// presents, and a photo-less sample garment shows the add affordance rather than a broken
    /// grid. It also pins the one-photo rule from the other side — a garment with fewer than two
    /// photos must NOT render the pager, so `wardrobe.item.carousel` is absent here.
    func testManagePhotosSheetOpensForASampleGarment() {
        openWardrobe()

        let sample = app.buttons["wardrobe.empty.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 6), "fresh store should show the empty state")
        sample.tap()

        XCTAssertTrue(app.staticTexts["Grey joggers"].waitForExistence(timeout: 6),
                      "sample closet should seed the joggers")
        app.staticTexts["Grey joggers"].firstMatch.tap()
        XCTAssertTrue(app.buttons["wardrobe.item.style"].waitForExistence(timeout: 6),
                      "item detail should open")

        // A sample garment has no photo at all, so the pager must not appear.
        XCTAssertFalse(app.descendants(matching: .any)["wardrobe.item.carousel"].exists,
                       "a garment with <2 photos must render the plain hero, not the pager")

        let menu = app.buttons["wardrobe.item.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6), "the ··· menu should exist")
        menu.tap()

        let manage = app.buttons["wardrobe.item.managePhotos"]
        XCTAssertTrue(manage.waitForExistence(timeout: 6),
                      "the menu should offer Manage photos with a count")
        manage.tap()

        // The sheet presents and offers the add affordance (the grid is empty for a sample piece).
        XCTAssertTrue(app.buttons["wardrobe.photos.add"].waitForExistence(timeout: 6),
                      "Manage photos should present with an add slot")
        snap("wardrobe-manage-photos")
    }

}
