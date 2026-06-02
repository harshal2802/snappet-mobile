import XCTest

/// UI coverage for the Calorie & Nutrition mini-app's core flow: open the app, add a food from
/// the bundled (sample) catalog to a meal, confirm it lands in the diary, and open History.
/// Mirrors `TipUITests`' entry pattern (open the App Library and tap the module card). Uses the
/// `-uiTestFreshStore` launch arg for an isolated, deterministic in-memory store.
final class NutritionUITests: XCTestCase {

    /// Launch straight into the App Library and open the Nutrition mini-app.
    private func openNutrition() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()

        let card = app.buttons["moduleCard.nutrition"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Nutrition card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        return app
    }

    /// Add a food to Breakfast and assert it appears in the diary.
    func testAddingFoodAppearsInDiary() {
        let app = openNutrition()

        let addBreakfast = app.buttons["nutrition.add.breakfast"]
        XCTAssertTrue(addBreakfast.waitForExistence(timeout: 6), "Breakfast 'Add food' should exist")
        addBreakfast.tap()

        // The Add-food sheet: search the sample catalog.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6), "Search field should appear")
        search.tap()
        search.typeText("banana")

        let result = app.buttons["nutrition.result.fdc-banana"]
        XCTAssertTrue(result.waitForExistence(timeout: 6), "A 'Banana' result should appear")
        result.tap()

        // Food detail → Add.
        let add = app.buttons["nutrition.detail.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 6), "Food detail 'Add' should exist")
        add.tap()

        // Back on the diary, the logged food should be listed.
        XCTAssertTrue(app.staticTexts["Banana, raw"].waitForExistence(timeout: 6),
                      "The logged food should appear in the diary")
    }

    /// History opens from the diary toolbar.
    func testHistoryOpens() {
        let app = openNutrition()
        let history = app.buttons["nutrition.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 6), "History toolbar button should exist")
        history.tap()
        // Either the empty state or a populated chart renders; the nav title is the stable anchor.
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 6),
                      "History screen should open")
    }
}
</content>
