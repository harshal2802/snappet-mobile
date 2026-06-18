import XCTest

/// UI coverage for the **climb-first hierarchy** (Quick Session redesign Phase 1): tapping "Climbing"
/// now opens an **"Add a climb"** sheet (TYPE → scale-aware GRADE → optional NAME → optional GYM) — NOT a
/// bare attempt row. The created climb is an **expandable card** whose attempts log underneath it (grade
/// captured ONCE on the card, never re-entered per attempt). The header name is a **tap-to-expand label**
/// (`freeform.climbName`, prompt 10 — no longer an inline field); renaming is via ⋯ → Edit details.
///
/// Drives the real path — Quick Start → tap Climbing → Add-a-climb sheet → pick a grade rung → name
/// "Cave Project" → "Add & log first attempt" → pick the Sent outcome → assert the climb card shows the
/// grade pill (V3), the Sent status, and the attempt row — and that the header LABEL reads "Cave Project".
/// Then renames via ⋯ → Edit details → addClimb.name → Save and asserts the label updates.
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

        // The header name is now a tap-to-expand LABEL (prompt 10) — a button whose `.label` is the climb
        // name, no longer a text field — reading the name captured in the sheet.
        let nameLabel = app.buttons["freeform.climbName"]
        XCTAssertTrue(nameLabel.waitForExistence(timeout: 4), "the climb card should show its name label")
        XCTAssertEqual(nameLabel.label, "Cave Project",
                       "the header label reads the name captured in the Add-a-climb sheet")

        // Rename via ⋯ → Edit details → addClimb.name → Save (the only rename path now, prompt 10).
        let climbMenu = app.buttons["freeform.climbMenu"]
        XCTAssertTrue(climbMenu.waitForExistence(timeout: 4), "the climb header should offer an options menu")
        climbMenu.tap()
        let editItem = app.buttons["freeform.editClimb"]
        XCTAssertTrue(editItem.waitForExistence(timeout: 4), "the climb Menu should offer 'Edit details'")
        editItem.tap()
        let editName = app.textFields["addClimb.name"]
        clearAndType(editName, "Slab")
        let save = app.buttons["addClimb.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4), "the edit sheet should show a single 'Save' CTA")
        save.tap()
        snap("05-renamed")

        // The header label now reads the new name (Cave Project → Slab), edited in place.
        let renamed = app.buttons["freeform.climbName"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 6), "the climb card should still show its name label")
        XCTAssertEqual(renamed.label, "Slab", "the renamed climb name should show on the header label")
    }

    /// Clear a text field's current value, then type `text` (which may end in "\n" to submit).
    private func clearAndType(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
}
