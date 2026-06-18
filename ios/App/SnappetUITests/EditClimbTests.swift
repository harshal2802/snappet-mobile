import XCTest

/// UI coverage for **editing a climb's details** (Quick Session redesign, prompt 09): a climb's header
/// Menu now has an **"Edit details"** item (above "Remove climb") that opens the SAME "Add a climb" sheet
/// PREFILLED from the climb, in an EDIT mode whose single CTA is **"Save"** (`addClimb.save`). Saving
/// overwrites THAT climb's fields in place — no duplicate, attempts preserved.
///
/// Drives the real path: Quick Start → add a V3 climb (named "Cave Project") → open its Menu → Edit
/// details → change the grade rung to V5 → Save → assert the card's `freeform.gradePill` reads the NEW
/// grade (V5) and there is still exactly ONE climb (no duplicate card).
///
/// Same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover session.
/// (Plain `XCTestCase`, matching `NamedClimbTests` — the whole SnappetUITests target carries the same
/// Swift-6 main-actor-isolation warnings on `XCUIApplication` access; this file mirrors that idiom.)
final class EditClimbTests: XCTestCase {
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

    /// Open the add-exercise menu and tap "Climbing" (which presents the "Add a climb" sheet).
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

    func testEditClimbDetailsUpdatesGradeInPlace() {
        openFreeformPlayer()

        // Add a V3 boulder named "Cave Project" via the Add-a-climb sheet (no first attempt — just the card).
        tapAddClimbingMenuItem()
        let typePicker = app.segmentedControls["addClimb.type"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 6), "the Add-a-climb sheet should present a TYPE picker")
        let v3 = app.buttons["addClimb.rung.V3"]
        XCTAssertTrue(v3.waitForExistence(timeout: 4), "the V-scale grade rail should offer V3")
        v3.tap()
        XCTAssertEqual(app.staticTexts["addClimb.gradeValue"].label, "V3", "tapping V3 should select it")
        typeIn(app.textFields["addClimb.name"], "Cave Project")
        let add = app.buttons["addClimb.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4), "the 'Add climb' CTA should be present")
        add.tap()
        snap("01-added-v3")

        // The card shows the V3 grade pill — exactly one climb so far.
        let pill = app.staticTexts["freeform.gradePill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6), "the climb card should show its grade pill")
        XCTAssertEqual(pill.label, "V3", "the freshly-added climb reads V3")
        XCTAssertEqual(app.staticTexts.matching(identifier: "freeform.gradePill").count, 1,
                       "there should be exactly one climb card")

        // Open the climb header Menu (the ellipsis, `freeform.climbMenu`) → tap "Edit details".
        let climbMenu = app.buttons["freeform.climbMenu"]
        XCTAssertTrue(climbMenu.waitForExistence(timeout: 4), "the climb header should offer an options menu")
        climbMenu.tap()
        let editItem = app.buttons["freeform.editClimb"]
        XCTAssertTrue(editItem.waitForExistence(timeout: 4), "the climb Menu should offer 'Edit details'")
        editItem.tap()
        snap("02-edit-sheet")

        // The sheet opened in EDIT mode: title "Edit climb", prefilled to V3, a single "Save" CTA.
        XCTAssertTrue(app.staticTexts["Edit climb"].waitForExistence(timeout: 4),
                      "the edit sheet should be titled 'Edit climb'")
        XCTAssertEqual(app.staticTexts["addClimb.gradeValue"].label, "V3",
                       "the edit sheet should be PREFILLED with the climb's grade (V3)")
        let save = app.buttons["addClimb.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4), "the edit sheet should show a single 'Save' CTA")
        XCTAssertFalse(app.buttons["addClimb.addAndLog"].exists,
                       "edit mode should NOT offer 'Add & log first attempt'")

        // Change the grade rung to V5 and Save.
        let v5 = app.buttons["addClimb.rung.V5"]
        XCTAssertTrue(v5.waitForExistence(timeout: 4), "the grade rail should offer V5")
        v5.tap()
        XCTAssertEqual(app.staticTexts["addClimb.gradeValue"].label, "V5", "tapping V5 should re-select it")
        save.tap()
        snap("03-saved-v5")

        // The card's grade pill now reads the NEW grade (V5), and there is STILL exactly one climb (no dup).
        let updated = app.staticTexts["freeform.gradePill"]
        XCTAssertTrue(updated.waitForExistence(timeout: 6), "the climb card should still show a grade pill")
        XCTAssertEqual(updated.label, "V5", "Saving the edit should update the climb's grade in place to V5")
        XCTAssertEqual(app.staticTexts.matching(identifier: "freeform.gradePill").count, 1,
                       "editing must NOT create a duplicate climb — there should still be exactly one")
    }
}
