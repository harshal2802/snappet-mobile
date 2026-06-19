import XCTest

/// UI coverage for the **Dance / Other disciplines + the six-discipline chooser** (Workout-Type Parity
/// Phase 5): Quick Start → the empty-state grid offers a Dance card (`freeform.cardDance`) → tapping it
/// adds a lightweight open-effort entity named "Dance" that renders the (discipline-aware) timed card with
/// "Add set". Fresh-store launch.
final class DanceOtherTests: XCTestCase {
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

    func testDanceFromSixTypeChooserAddsAnOpenEffortCard() {
        openFreeformPlayer()

        // The empty-state chooser now offers Dance (and Running / Other) alongside the original three.
        let dance = app.buttons["freeform.cardDance"]
        XCTAssertTrue(dance.waitForExistence(timeout: 6), "the six-discipline chooser should offer Dance")
        dance.tap()

        // A dance card appears (named "Dance") with an "Add set" affordance to log an open-effort duration.
        let name = app.staticTexts["freeform.timedName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the dance card header should appear")
        XCTAssertEqual(name.label, "Dance")
        XCTAssertTrue(app.buttons["freeform.addSet"].waitForExistence(timeout: 3),
                      "the dance card should let you log time")
    }
}
