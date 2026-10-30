import XCTest

/// Prompt 215: Kilter Settings → Board photo → (sample photo) → corners → line-up check → save → it shows
/// behind the holds on a climb, with the "Your photo" chip; then remove it.
final class KilterBoardPhotoUITests: XCTestCase {
    private func snap(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }

    func testAddAPhotoOfYourBoardThenSeeItOnAClimb() {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog", "-uiTestBoardPhotoSample"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.kilter"]
        var tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        XCTAssertTrue(app.buttons["kilter.climbRow"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["kilter.more"].tap()
        app.buttons["Settings"].tap()
        let row = app.buttons["kilter.settings.boardPhoto"]
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        let sample = app.buttons["kilter.boardPhoto.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 4))
        sample.tap()
        XCTAssertTrue(app.buttons["kilter.boardPhoto.next"].waitForExistence(timeout: 4))
        sleep(1); snap(app, "photo-corners")
        app.buttons["kilter.boardPhoto.next"].tap()
        let save = app.buttons["kilter.boardPhoto.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        sleep(1); snap(app, "photo-lineup")
        save.tap()

        // Back to browse → a climb shows the photo.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["kilter.climbRow"].firstMatch.tap()
        let chip = app.buttons["kilter.boardPhoto.chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 6), "the climb shows your photo")
        sleep(1); snap(app, "photo-climb")

        // The chip reopens the sheet, where Remove takes it away.
        chip.tap()
        let remove = app.buttons["kilter.boardPhoto.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 4))
        remove.tap()
        XCTAssertFalse(chip.waitForExistence(timeout: 2), "removed")
    }
}
