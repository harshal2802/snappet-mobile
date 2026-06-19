import XCTest

/// UI coverage for **timing as an orthogonal axis** (Workout-Type Parity Phase 3): a strength set can be
/// reps × weight AND timed. Drives Quick Start → add a Lifting exercise → "Time this set"
/// (`freeform.timeThisSet`) → the `TimedSetCover` (count-up) → bump the weight → STOP & LOG → assert the
/// logged row carries the combined "N × W kg · M:SS" measure. Fresh-store launch like the rest of the suite.
final class TimedStrengthSetTests: XCTestCase {
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

    func testTimeThisSetLogsCombinedRepsWeightAndDuration() {
        openFreeformPlayer()
        addLiftingExercise()

        // The new footer action opens the count-up "Time this set" FOCUS cover.
        let timeBtn = app.buttons["freeform.timeThisSet"]
        XCTAssertTrue(timeBtn.waitForExistence(timeout: 6), "the strength card should offer Time this set")
        timeBtn.tap()

        let timer = app.staticTexts["timedSet.timer"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5), "the timed-set cover should show a count-up timer")

        // Give the set a load: bump weight 0 → 5 (2 × 2.5) so the row proves reps × weight × time together.
        let weightPlus = app.buttons["timedSet.weight.plus"]
        XCTAssertTrue(weightPlus.waitForExistence(timeout: 3), "the cover should have a weight stepper")
        weightPlus.tap(); weightPlus.tap()

        // Let the wall-clock timer accrue a non-zero duration, then STOP & LOG.
        sleep(2)
        app.buttons["timedSet.stop"].tap()

        // The committed row carries the combined measure: "8 × 5 kg · M:SS" (reps × weight · duration).
        let combined = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '× 5 kg · '")).firstMatch
        XCTAssertTrue(combined.waitForExistence(timeout: 6),
                      "the timed strength set should log a combined reps × weight · duration row")
    }
}
