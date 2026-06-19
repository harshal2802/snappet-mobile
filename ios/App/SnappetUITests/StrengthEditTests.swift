import XCTest

/// UI coverage for the strength **Edit details** flow (Workout-Type Parity, strength polish): the card's ⋯
/// menu (`freeform.entityMenu`) → "Edit details" (`freeform.editEntity`) opens the StrengthEditSheet where
/// you can rename the exercise (and set its default prescription); Save updates the card header. Fresh-store.
final class StrengthEditTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func openFreeformPlayer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 8)
            || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 2))
    }

    private func addLiftingExercise() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let opt = app.buttons["Lifting exercise"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4)); opt.tap()
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let add = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 4)); add.tap()
    }

    func testEditDetailsRenamesTheExercise() {
        openFreeformPlayer()
        addLiftingExercise()

        let menu = app.buttons["freeform.entityMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 6), "the strength card should have an options menu")
        menu.tap()
        let edit = app.buttons["freeform.editEntity"]
        XCTAssertTrue(edit.waitForExistence(timeout: 4), "the menu should offer Edit details")
        edit.tap()

        let nameField = app.textFields["editStrength.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "the edit sheet should have a name field")
        nameField.tap()
        nameField.typeText("Front Squat")
        app.buttons["editStrength.save"].tap()

        // The card header (a tap-to-expand Button whose label is the name) now reads the new name.
        let header = app.buttons["freeform.entityName"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.label, "Front Squat", "Edit details should rename the exercise")
    }
}
