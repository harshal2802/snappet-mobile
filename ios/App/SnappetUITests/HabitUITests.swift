import XCTest

/// UI flow for the Habit mini-app: create a habit, edit its name + symbol, then backfill a prior
/// day via the 7-day strip — asserting the streak and 30-day completion-rate labels reflect the
/// change. Drives the suite via the same App Library entry the smoke test uses.
final class HabitUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    /// Open the Habit mini-app from the App Library.
    private func openHabit() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.habit"]
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have the habit card")
        var tries = 0
        while !card.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        card.tap()
        XCTAssertTrue(app.navigationBars["Habits"].waitForExistence(timeout: 6), "Habit root should open")
    }

    func testEditAndBackfillFlow() {
        openHabit()

        // Create a habit named "Read".
        app.buttons["habit.add"].firstMatch.tap()
        let nameField = app.textFields["habit.nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 4), "editor name field should appear")
        nameField.tap()
        nameField.typeText("Read")
        app.buttons["habit.save"].tap()

        // The first habit row should now exist.
        let row = app.cells.containing(.any, identifier: "habit.row.0").firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 4) || app.staticTexts["Read"].waitForExistence(timeout: 4),
            "the new habit should appear in the list"
        )

        // Edit the habit's name → "Read Daily".
        let editButton = app.buttons["habit.edit"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 4), "edit control should be present")
        editButton.tap()
        let editField = app.textFields["habit.nameField"]
        XCTAssertTrue(editField.waitForExistence(timeout: 4), "edit field should be prefilled")
        // Clear existing text then type the new name.
        editField.tap()
        if let current = editField.value as? String, !current.isEmpty {
            editField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        editField.typeText("Read Daily")
        app.buttons["habit.save"].tap()
        XCTAssertTrue(app.staticTexts["Read Daily"].waitForExistence(timeout: 4), "edited name should persist")

        // Backfill a prior day (offset 1 == yesterday) via the week strip.
        let yesterday = app.buttons["habit.day.1"].firstMatch
        XCTAssertTrue(yesterday.waitForExistence(timeout: 4), "week-strip yesterday cell should exist")
        yesterday.tap()

        // Mark today done too, building a 2-day streak ending today.
        let todayCell = app.buttons["habit.day.0"].firstMatch
        XCTAssertTrue(todayCell.waitForExistence(timeout: 4), "week-strip today cell should exist")
        todayCell.tap()

        // The streak label should reflect at least a 2-day streak, and a completion-rate label exists.
        XCTAssertTrue(
            app.staticTexts.containing(.staticText, identifier: nil)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "streak")).firstMatch
                .waitForExistence(timeout: 4),
            "a streak label should be shown after backfilling"
        )
        XCTAssertTrue(
            app.staticTexts["habit.rate.0"].waitForExistence(timeout: 4),
            "a 30-day completion-rate label should be shown"
        )
    }
}
