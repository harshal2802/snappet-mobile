import XCTest

/// UI coverage for the **frictionless free-flow climb naming** (issue #158 §C, reversing
/// workout-with-timer PR 5's blocking prompt): in the freeform player, tapping "Climbing" adds the climb
/// IMMEDIATELY (no "Name this climb" alert), named "Climbing" by default. The section header is an inline
/// TextField (`freeform.climbName`) you can rename anytime; the typed name persists on the
/// SessionExercise's `displayName`, blank → "Climbing" (the pure `SetMeasure.climbName`).
///
/// Drives the real path — Quick Start → tap Climbing (added immediately, no alert) → assert the inline
/// name field defaults to "Climbing" → rename inline to "Cave Project" → Add attempt → grade "V3" → Add →
/// assert the attempt logs under the renamed climb.
///
/// Same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover active
/// session. Extract shots with `xcrun xcresulttool export attachments`.
final class NamedClimbTests: XCTestCase {
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

    /// Apps → Workout dashboard → Quick Start, landing in the routineless freeform player.
    private func openFreeformPlayer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the workout module card should be in the App Library")
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6), "Quick Start should be on the dashboard")
        quick.tap()
        XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 8)
            || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 2),
            "the freeform player should open")
    }

    /// Open the add-exercise menu and tap "Climbing" (which now adds the climb immediately — #158 §C).
    private func tapAddClimbingMenuItem() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Climbing"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "menu item Climbing should appear")
        opt.tap()
    }

    /// Tap the "Add set" button for the most recently added exercise (robust to a SwiftUI `Menu` tap
    /// occasionally double-firing under XCUITest — always log into the newest exercise).
    private func tapAddSetForLastExercise() {
        let adds = app.buttons.matching(identifier: "freeform.addSet")
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 4), "an Add set button should exist")
        adds.element(boundBy: adds.count - 1).tap()
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    func testClimbAddsImmediatelyAndRenamesInline() {
        openFreeformPlayer()
        snap("01-freeform")

        // Tap "Climbing" → the climb is added IMMEDIATELY; the old blocking "Name this climb" alert is
        // gone (#158 §C). Assert the alert's name field never appears.
        tapAddClimbingMenuItem()
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "placeholderValue == %@",
                                                           "Climb name (e.g. Cave Project)")).firstMatch
                        .waitForExistence(timeout: 2),
                       "tapping Climbing must NOT present a blocking name prompt anymore")

        // The climb is added with a directly-editable inline name field defaulting to "Climbing".
        let nameField = app.textFields["freeform.climbName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 6), "an inline climb-name field should appear")
        XCTAssertEqual(nameField.value as? String, "Climbing", "a new climb defaults to 'Climbing'")
        snap("02-added")

        // Rename inline to a custom name; it persists as the field's value (SessionExercise.displayName).
        clearAndType(nameField, "Cave Project\n")
        XCTAssertEqual(nameField.value as? String, "Cave Project",
                       "the custom climb name should persist inline")
        snap("03-renamed")

        // Log an attempt under the named climb.
        tapAddSetForLastExercise()
        let grade = app.textFields["logset.grade"]
        XCTAssertTrue(grade.waitForExistence(timeout: 6), "the climb attempt log sheet should open")
        typeIn(grade, "V3")
        let add = app.buttons["logset.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4) && add.isEnabled,
                      "a graded attempt should enable the Add button")
        add.tap()

        // The attempt logs as a row reading its distinctive grade ("V3 · Sent" via SetMeasure.summary).
        sleep(1); snap("04-logged")
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "V3")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6),
                      "the attempt row should show the distinctive grade (V3) under the named climb")
        // …and the named-climb field is still present alongside the logged attempt.
        XCTAssertEqual(app.textFields["freeform.climbName"].value as? String, "Cave Project",
                       "the named-climb field should remain while its attempts are logged")
    }

    /// Clear a text field's current value, then type `text` (which may end in "\n" to submit).
    private func clearAndType(_ field: XCUIElement, _ text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
}
