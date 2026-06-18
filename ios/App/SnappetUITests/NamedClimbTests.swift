import XCTest

/// UI coverage for the **climb-first hierarchy** (Quick Session redesign Phase 1): tapping "Climbing"
/// now opens an **"Add a climb"** sheet (TYPE → scale-aware GRADE → optional NAME → optional GYM) — NOT a
/// bare attempt row. The created climb is an **expandable card** whose attempts log underneath it (grade
/// captured ONCE on the card, never re-entered per attempt). The section header keeps the inline
/// `freeform.climbName` TextField for renaming.
///
/// Drives the real path — Quick Start → tap Climbing → Add-a-climb sheet → pick a grade rung → name
/// "Cave Project" → "Add & log first attempt" → pick the Sent outcome → assert the climb card shows the
/// grade pill (V3), the Sent status, and the attempt row — and that the inline name is "Cave Project".
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

    /// Open the add-exercise menu and tap "Climbing" (which now presents the "Add a climb" sheet).
    private func tapAddClimbingMenuItem() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Climbing"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "menu item Climbing should appear")
        opt.tap()
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    func testAddClimbSheetCreatesAnExpandableCardWithAttempts() {
        openFreeformPlayer()
        snap("01-freeform")

        // Tap "Climbing" → the "Add a climb" sheet appears (the new climb-first entry point).
        tapAddClimbingMenuItem()
        let typePicker = app.segmentedControls["addClimb.type"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 6), "the Add-a-climb sheet should present a TYPE picker")
        snap("02-add-sheet")

        // Pick a grade RUNG (a discrete picker, never free-text). V3 is distinctive and easy to assert.
        let rung = app.buttons["addClimb.rung.V3"]
        XCTAssertTrue(rung.waitForExistence(timeout: 4), "the scale-aware grade rail should offer V-scale rungs")
        rung.tap()
        XCTAssertEqual(app.staticTexts["addClimb.gradeValue"].label, "V3",
                       "tapping a rung should select that grade")

        // Name the climb, then "Add & log first attempt" (auto-opens the inline outcome strip).
        typeIn(app.textFields["addClimb.name"], "Cave Project")
        snap("03-graded-named")
        let addAndLog = app.buttons["addClimb.addAndLog"]
        XCTAssertTrue(addAndLog.waitForExistence(timeout: 4), "the prominent CTA should be present")
        addAndLog.tap()

        // The card auto-expands to its inline outcome strip — pick "Sent" (a boulder outcome).
        let sent = app.buttons["freeform.outcome.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 6),
                      "'Add & log first attempt' should open the inline outcome strip on the new card")
        sent.tap()
        sleep(1); snap("04-logged")

        // The climb card shows the grade pill (V3), the Sent status, and the attempt row (outcome only,
        // not the grade — the per-attempt SetMeasure.attemptRow).
        let pill = app.staticTexts["freeform.gradePill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6), "the climb card should show its grade pill")
        XCTAssertEqual(pill.label, "V3", "the grade pill should read the climb's grade (V3)")
        XCTAssertTrue(app.staticTexts["freeform.climbStatus"].waitForExistence(timeout: 4),
                      "the climb card should show a rolled-up status badge once an attempt is logged")
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "the logged attempt should appear as a row under the card")

        // The inline name field reads the name captured in the sheet (Cave Project), and is renameable.
        let nameField = app.textFields["freeform.climbName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 4), "the climb card should keep an inline name field")
        XCTAssertEqual(nameField.value as? String, "Cave Project",
                       "the climb keeps the name captured in the Add-a-climb sheet")

        // Rename inline — it persists as the field's value (SessionExercise.displayName).
        clearAndType(nameField, "Slab\n")
        XCTAssertEqual(nameField.value as? String, "Slab", "the renamed climb name should persist inline")
        snap("05-renamed")
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
