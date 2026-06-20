import XCTest

/// UI coverage for the **post-workout completion moment** (issue #158 §D): in the freeform player, the
/// command-bar Finish opens an in-cover summary screen ("Workout Complete" + Duration/Sets/headline
/// stats + Done / View detail / Keep going), instead of dropping straight to the dashboard. Keep going
/// returns to the logbook (no save); Done saves & exits. Milestone confetti is covered by the pure
/// FreeformSummary unit tests. Fresh-store launch like the rest of the suite.
final class CompletionMomentTests: XCTestCase {
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

    private func tapFinish() {
        let finish = app.buttons["freeform.finish"]
        if !finish.exists { app.swipeUp() }
        XCTAssertTrue(finish.waitForExistence(timeout: 6), "Finish should be available")
        finish.tap()
    }

    func testFinishOpensCompletionSummaryWithKeepGoingAndDone() {
        openFreeformPlayer()
        addLiftingExercise()

        // Log one set via the inline quick-add (bump weight so it's a real lift).
        app.buttons["freeform.quickWeight.plus"].tap()
        app.buttons["freeform.quickWeight.plus"].tap()
        app.buttons["freeform.quickLog"].tap()

        // Finish opens the completion summary (not the dashboard).
        tapFinish()
        XCTAssertTrue(app.staticTexts["Workout Complete"].waitForExistence(timeout: 6),
                      "Finish should open the completion summary")
        XCTAssertTrue(app.staticTexts["Sets"].exists, "the summary should show completion stats")

        // Keep going returns to the logbook without saving (the add-exercise affordance is back).
        app.buttons["freeform.keepGoing"].tap()
        XCTAssertTrue(app.buttons["freeform.addExercise"].waitForExistence(timeout: 6),
                      "Keep going should return to the logbook")

        // Finish again → Done saves & exits to the dashboard.
        tapFinish()
        let done = app.buttons["freeform.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 6), "the summary's Done button should appear")
        done.tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 8),
                      "Done should save & exit to the dashboard")
    }

    /// E2: "View detail" pushes the redesigned, type-adaptive session detail (the shared `SessionRecap`
    /// hero + per-discipline cards), not the old flat LabeledContent list.
    func testViewDetailOpensTypeAdaptiveRecap() {
        openFreeformPlayer()
        addLiftingExercise()
        app.buttons["freeform.quickWeight.plus"].tap()
        app.buttons["freeform.quickWeight.plus"].tap()
        app.buttons["freeform.quickLog"].tap()
        tapFinish()
        let viewDetail = app.buttons["freeform.viewDetail"]
        XCTAssertTrue(viewDetail.waitForExistence(timeout: 6), "the summary's View detail button should appear")
        viewDetail.tap()
        XCTAssertTrue(app.navigationBars["Session"].waitForExistence(timeout: 6),
                      "View detail should push the session detail")
        // The type-adaptive recap hero for a strength session shows Volume / Sets / PRs cells.
        XCTAssertTrue(app.staticTexts["Volume"].waitForExistence(timeout: 4)
            || app.staticTexts["Sets"].waitForExistence(timeout: 2),
            "the session detail should render the type-adaptive recap hero")
    }

    /// All-axis edit follow-up: the session detail's Edit mode still works end-to-end after the
    /// `SetEditFields` refactor — Edit appears, the per-set fields render, Save round-trips back to read mode.
    func testEditSetsFromSessionDetail() {
        openFreeformPlayer()
        addLiftingExercise()
        app.buttons["freeform.quickWeight.plus"].tap()
        app.buttons["freeform.quickLog"].tap()
        tapFinish()
        let viewDetail = app.buttons["freeform.viewDetail"]
        XCTAssertTrue(viewDetail.waitForExistence(timeout: 6))
        viewDetail.tap()
        XCTAssertTrue(app.navigationBars["Session"].waitForExistence(timeout: 6))

        let edit = app.buttons["session.editSets"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "a completed set makes the Edit button appear")
        edit.tap()
        // Entering edit mode swaps the toolbar to Cancel/Save (top-of-screen, always in the tree).
        let save = app.buttons["session.saveSets"]
        XCTAssertTrue(save.waitForExistence(timeout: 4), "Edit enters edit mode (Save appears)")
        // The per-set tile is below the recap header — scroll to reveal the refactored SetEditFields.
        app.swipeUp()
        XCTAssertTrue(app.textFields["session.editWeight"].waitForExistence(timeout: 4),
                      "edit mode shows the per-set reps/weight fields for a strength set")
        save.tap()
        XCTAssertTrue(app.buttons["session.editSets"].waitForExistence(timeout: 5),
                      "Save round-trips back to read mode without a crash")
    }
}
