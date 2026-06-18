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
}
