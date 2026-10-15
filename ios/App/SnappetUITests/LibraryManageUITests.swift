import XCTest

/// Library L3 (prompt 185): rename (+ Undo), merge, pin and hide. Seeded by `-uiTestSeedRoutineHistory` — its climbs
/// are "V2 boulder" … "V5 boulder" (one edit apart, so they're each other's look-alikes).
@MainActor
final class LibraryManageUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Library"].tap()
        let chip = app.descendants(matching: .any).matching(identifier: "library.chip.climb").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        chip.tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'library.yours.row' AND label CONTAINS %@", title)).firstMatch
    }

    private func manage(_ item: String) {
        app.buttons.matching(identifier: "activity.manage").firstMatch.tap()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 3), item)
        button.tap()
    }

    func testRenameThenUndo() {
        XCTAssertTrue(row("V4 boulder").waitForExistence(timeout: 6))
        row("V4 boulder").tap()
        manage("Rename…")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Pink arete")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Pink arete"].waitForExistence(timeout: 4), "the page follows the new name")
        snap("01-renamed")

        let undo = app.buttons.matching(identifier: "activity.undo").firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(app.navigationBars["V4 boulder"].waitForExistence(timeout: 4), "undo restores it")
    }

    func testMergeLookalikes() {
        XCTAssertTrue(row("V5 boulder").waitForExistence(timeout: 6))
        row("V5 boulder").tap()
        manage("Merge with…")
        let confirm = app.buttons.matching(identifier: "library.merge.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        XCTAssertFalse(confirm.isEnabled, "nothing is pre-ticked — merging rewrites history")
        XCTAssertFalse(app.staticTexts["Looks like the same climb"].exists, "V2–V4 aren't look-alikes of V5")
        app.buttons.matching(NSPredicate(format: "identifier == 'library.merge.row' AND label CONTAINS 'V4 boulder'")).firstMatch.tap()
        XCTAssertTrue(confirm.isEnabled)
        snap("02-merge-sheet")
        confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Merged'")).firstMatch
            .waitForExistence(timeout: 4), "merged, with Undo")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Fewer climbs now — the merged ones are one.
        XCTAssertTrue(row("V5 boulder").waitForExistence(timeout: 4))
        XCTAssertFalse(row("V4 boulder").exists, "the picked climb folded into V5 boulder")
        XCTAssertTrue(row("V3 boulder").exists, "the others are untouched")
        snap("03-after-merge")
    }

    func testSwipeToPinAndHide() {
        XCTAssertTrue(row("V3 boulder").waitForExistence(timeout: 6))
        row("V3 boulder").swipeRight()
        app.buttons["Pin"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "library.yours.row").firstMatch.label.contains("V3 boulder"),
                      "pinned leads")
        snap("04-pinned")

        row("V2 boulder").swipeLeft()
        app.buttons["Hide"].tap()
        XCTAssertFalse(row("V2 boulder").waitForExistence(timeout: 2), "hidden from the list")
        app.buttons.matching(identifier: "library.sort").firstMatch.tap()
        let show = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Show hidden'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 3) || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show hidden'")).firstMatch.exists)
        (show.exists ? show : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show hidden'")).firstMatch).tap()
        XCTAssertTrue(row("V2 boulder").waitForExistence(timeout: 3), "shown again with Show hidden")
        snap("05-show-hidden")
    }
}
