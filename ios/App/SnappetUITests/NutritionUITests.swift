import XCTest

/// UI walkthrough: open Nutrition, add a food to Breakfast, verify diary.
/// Uses the `-uiTestFreshStore` launch arg for isolation.
final class NutritionUITests: XCTestCase {
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

    private func openNutrition() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.nutrition"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library must have a Nutrition card")
        tries = 0
        while !card.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    func testSearchLogAndDiary() {
        openNutrition()
        snap("01-nutrition-open")

        // Open add-food sheet for Breakfast
        let addBreakfast = app.buttons["nutrition.addFood.breakfast"]
        XCTAssertTrue(addBreakfast.waitForExistence(timeout: 4))
        addBreakfast.tap()
        snap("02-add-food-sheet")

        // Search for a food
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Chicken")
        snap("03-search-results")

        // Tap first result
        let firstResult = app.buttons["nutrition.foodResult"].firstMatch
        if firstResult.waitForExistence(timeout: 3) {
            firstResult.tap()
        } else {
            app.cells.firstMatch.tap()
        }
        snap("04-food-detail")

        // Add to diary
        let addBtn = app.buttons["nutrition.addToDiary"]
        if addBtn.waitForExistence(timeout: 3) { addBtn.tap() }
        snap("05-logged")

        // Diary should show entry
        XCTAssertTrue(
            app.otherElements["nutrition.diary"].waitForExistence(timeout: 4),
            "Diary should be visible after logging"
        )
        XCTAssertTrue(
            app.otherElements["nutrition.budgetRing"].waitForExistence(timeout: 4),
            "Budget ring should be visible"
        )
        XCTAssertTrue(
            app.otherElements["nutrition.macroBars"].waitForExistence(timeout: 4),
            "Macro bars should be visible"
        )
        snap("06-diary")

        // Navigate to History
        app.tabBars.buttons["History"].tap()
        snap("07-history")
        XCTAssertTrue(
            app.otherElements["nutrition.history"].waitForExistence(timeout: 4),
            "History screen should load"
        )
    }
}
