import XCTest

/// Every picker is the Library (Library redesign L4b, prompt 187): Quick Session "Add exercise" and the routine
/// builder open on Yours · Most used with a "Last: …" line, the catalog under Explore. Seeded by
/// `-uiTestSeedActivityClips` (routine history with bench sets).
@MainActor
final class LibraryPickerUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedActivityClips"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private var benchInYours: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'picker.yours.row' AND label CONTAINS 'Bench'")).firstMatch
    }

    func testQuickSessionPickerOpensOnYoursWithLastTime() {
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        app.buttons["Lifting exercise"].tap()

        let mode = app.segmentedControls.matching(identifier: "picker.mode").firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.buttons["Yours"].isSelected, "opens on Yours when you've logged things")
        XCTAssertTrue(benchInYours.waitForExistence(timeout: 5), "your bench is offered")
        XCTAssertTrue(benchInYours.label.contains("Last:"), benchInYours.label)
        snap("01-quick-yours")

        benchInYours.tap()
        mode.buttons["Explore"].tap()
        let catalogRow = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'")).firstMatch
        XCTAssertTrue(catalogRow.waitForExistence(timeout: 5), "Explore is the catalog")
        snap("02-quick-explore")

        app.buttons["picker.add"].tap()
        let name = any("freeform.entityName")
        XCTAssertTrue(name.waitForExistence(timeout: 8), "the session player")
        XCTAssertTrue(name.label.contains("Bench"), name.label)
        snap("03-quick-added")

        // Clean up: finish + discard so the live workout doesn't leak into the next launch.
        app.buttons["freeform.finish"].tap()
        let discard = app.buttons["freeform.discard"]
        if discard.waitForExistence(timeout: 4) {
            discard.tap()
            let confirm = app.buttons["Discard (don't save)"]
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        }
    }

    func testRoutineBuilderPicksFromYours() {
        app.segmentedControls.buttons["Routines"].tap()
        let add = app.buttons["routines.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        app.buttons["routines.menu.new"].tap()
        let addBlock = any("routineEditor.addBlock")
        XCTAssertTrue(addBlock.waitForExistence(timeout: 5))
        addBlock.tap()

        let mode = app.segmentedControls.matching(identifier: "picker.mode").firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(mode.buttons["Yours"].isSelected)
        XCTAssertTrue(benchInYours.waitForExistence(timeout: 5))
        snap("04-routine-yours")
        benchInYours.tap()
        app.buttons["libraryPicker.add"].tap()

        let blocks = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Blocks (1)'")).firstMatch
        XCTAssertTrue(blocks.waitForExistence(timeout: 5), "a block was added")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Bench'")).firstMatch.exists,
                      "it's the bench, prescribed from last time")
        snap("05-routine-block")
    }
}
