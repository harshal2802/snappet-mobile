import XCTest

/// UI coverage for the Tip mini-app's new history + editable-preset flow:
/// committing a bill records a row in History, and editing a preset percentage
/// updates the on-screen preset button. Mirrors `SuiteSmokeTests`' entry pattern
/// (open the App Library and tap the Tip card).
final class TipUITests: XCTestCase {

    /// Launch straight into the App Library and open the Tip mini-app.
    private func openTip() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()

        let card = app.buttons["moduleCard.tip"]
        // Tip is in the Finance section (below the fold); scroll until the LazyVGrid realizes it.
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Tip card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        return app
    }

    /// Enter a bill, pick a preset, then open History and assert a row was saved.
    func testCommittingCalculationAppearsInHistory() {
        let app = openTip()

        let bill = app.textFields["tip.bill"]
        XCTAssertTrue(bill.waitForExistence(timeout: 6), "Bill field should be present")
        bill.tap()
        bill.typeText("42.50")

        // Pick a preset (segmented control segment) before committing.
        let preset = app.buttons["tip.preset.1"]
        if preset.waitForExistence(timeout: 3) { preset.tap() }

        // Commit by dismissing the keypad.
        app.toolbars.buttons["Done"].firstMatch.tap()

        // Open History.
        let history = app.buttons["tip.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 6), "History toolbar button should exist")
        history.tap()

        let row = app.descendants(matching: .any)["tip.historyRow"]
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 6),
                      "A history row should appear after committing a calculation")
    }

    /// Edit a preset percentage in the editor sheet and confirm the preset button reflects it.
    func testEditingPresetUpdatesButton() {
        let app = openTip()

        // Capture the current first-preset value (presets live in @AppStorage, which persists
        // across runs, so assert a relative +1% change rather than a fixed 15→16).
        let presetButton = app.buttons["tip.preset.0"]
        XCTAssertTrue(presetButton.waitForExistence(timeout: 6), "First preset segment should exist")
        let before = Int(presetButton.label.replacingOccurrences(of: "%", with: "")) ?? -1

        // Open the preset editor.
        let edit = app.buttons["tip.editPresets"]
        XCTAssertTrue(edit.waitForExistence(timeout: 6), "Edit presets button should exist")
        edit.tap()

        // Bump preset 0 up via its stepper (increment).
        let stepper = app.steppers["tip.presetEdit.0"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 6), "Preset 0 stepper should exist")
        stepper.buttons.element(boundBy: 1).tap()

        // Dismiss the sheet.
        app.buttons["tip.presetEdit.done"].tap()

        // The first preset segment should now read one percentage point higher.
        let updated = app.buttons["tip.preset.0"]
        XCTAssertTrue(updated.waitForExistence(timeout: 6), "Updated preset segment should exist")
        let after = Int(updated.label.replacingOccurrences(of: "%", with: "")) ?? -2
        XCTAssertEqual(after, before + 1, "Editing preset 0 should bump it up by 1%")
    }
}
