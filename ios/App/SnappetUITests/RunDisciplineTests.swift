import XCTest

/// UI coverage for the **running discipline** (Workout-Type Parity Phase 4): Quick Start → add a Running
/// entity (add-menu) → the run card → "Log a leg" (`freeform.logLeg`) → the distance/time sheet → assert
/// the logged leg shows the combined distance · time · derived-pace measure. Fresh-store launch.
final class RunDisciplineTests: XCTestCase {
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

    func testLogARunLegShowsCombinedDistanceTimePace() {
        openFreeformPlayer()

        // Add a Running entity via the add-menu.
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let run = app.buttons["Running"]
        XCTAssertTrue(run.waitForExistence(timeout: 4), "the add-menu should offer Running"); run.tap()

        // The run card auto-expands → Log a leg.
        let logLeg = app.buttons["freeform.logLeg"]
        XCTAssertTrue(logLeg.waitForExistence(timeout: 6), "the run card should offer Log a leg"); logLeg.tap()

        // Fill the sheet: 5 (km) in 25 min → derived pace 5:00/km.
        let dist = app.textFields["runLeg.distance"]
        XCTAssertTrue(dist.waitForExistence(timeout: 4), "the leg sheet should have a distance field")
        dist.tap(); dist.typeText("5")
        let mins = app.textFields["runLeg.minutes"]
        XCTAssertTrue(mins.waitForExistence(timeout: 2)); mins.tap(); mins.typeText("25")

        let logBtn = app.buttons["runLeg.log"]
        XCTAssertTrue(logBtn.waitForExistence(timeout: 2)); logBtn.tap()

        // The leg row carries the combined "5 km · 25:00 · 5:00/km" measure.
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5 km · '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "the logged run leg should show distance · time · derived pace")
    }
}
