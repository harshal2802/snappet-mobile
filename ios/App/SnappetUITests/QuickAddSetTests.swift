import XCTest

/// UI coverage for **faster set entry** (issue #158 §B): a `.repsWeight` exercise in the freeform
/// player shows keyboard-free inline steppers (`freeform.quickReps` / `freeform.quickWeight`) + a one
/// -tap `freeform.quickLog` that appends a set WITHOUT opening `LogSetSheet`; and the one-tap Repeat
/// control (`freeform.repeatSet`) is value-labelled ("Repeat 10 × 5 kg"). Drives the real Quick Start
/// → add a Lifting exercise → step → Log → Repeat path. Fresh-store launch like the rest of the suite.
final class QuickAddSetTests: XCTestCase {
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
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the workout module card should be in the App Library")
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6), "Quick Start should be on the dashboard")
        quick.tap()
        XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 8)
            || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 2),
            "the freeform player should open")
    }

    private func addLiftingExercise() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Lifting exercise"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "the Lifting menu item should appear")
        opt.tap()
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker should list exercises")
        row.tap()
        let addLift = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addLift.waitForExistence(timeout: 4), "the picker's Add commit button should appear")
        addLift.tap()
    }

    func testInlineQuickAddLogsWithoutKeyboardAndRepeatIsValueLabelled() {
        openFreeformPlayer()
        addLiftingExercise()

        // The inline quick-add controls appear for a reps & weight exercise.
        let repsPlus = app.buttons["freeform.quickReps.plus"]
        XCTAssertTrue(repsPlus.waitForExistence(timeout: 6), "an inline reps stepper should appear")
        let weightPlus = app.buttons["freeform.quickWeight.plus"]
        XCTAssertTrue(weightPlus.waitForExistence(timeout: 2), "an inline weight stepper should appear")
        let log = app.buttons["freeform.quickLog"]
        XCTAssertTrue(log.waitForExistence(timeout: 2), "an inline Log button should appear")

        // Keyboard-free: bump reps 8 → 10 and weight 0 → 5 (2 × 2.5) using the +/- controls only.
        repsPlus.tap()
        repsPlus.tap()
        weightPlus.tap()
        weightPlus.tap()

        // Log it — a set row appears reading "10 × 5 kg", and NO sheet was opened. Match the set-row
        // value EXACTLY (not CONTAINS): the value-labelled Repeat control also renders "Repeat 10 × 5 kg".
        log.tap()
        let value = app.staticTexts.matching(NSPredicate(format: "label == '10 × 5 kg'"))
        XCTAssertTrue(value.firstMatch.waitForExistence(timeout: 6),
                      "the inline-logged set should read 10 × 5 kg")
        XCTAssertEqual(value.count, 1, "exactly one set logged via quick-add")
        XCTAssertFalse(app.buttons["logset.add"].exists, "quick-add must NOT open the log sheet")

        // The one-tap Repeat is value-labelled (reads the set it duplicates) and matched by id.
        let repeatBtn = app.buttons["freeform.repeatSet"]
        XCTAssertTrue(repeatBtn.waitForExistence(timeout: 4), "a logged set should offer a Repeat control")
        XCTAssertTrue(repeatBtn.label.contains("Repeat") && repeatBtn.label.contains("10 × 5 kg"),
                      "Repeat should be value-labelled, got '\(repeatBtn.label)'")

        // Tapping Repeat appends a second identical set (no sheet) — the value text rises to 2.
        repeatBtn.tap()
        let twoValues = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: value)
        XCTAssertEqual(XCTWaiter().wait(for: [twoValues], timeout: 6), .completed,
                       "Repeat should append a second identical 10 × 5 kg set")
    }
}
