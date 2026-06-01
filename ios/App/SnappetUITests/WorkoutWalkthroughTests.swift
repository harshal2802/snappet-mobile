import XCTest

/// End-to-end UI walkthrough of the Workout tracker, now that every row is a Button (reliably
/// hittable). Drives detail screens + the full player→finish flow, asserting key transitions and
/// screenshotting each step. Extract shots with `xcresulttool export attachments`.
final class WorkoutWalkthroughTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        // Isolated, empty in-memory store so the run is deterministic and never inherits a
        // leftover active session (which would trigger the start-conflict dialog instead of
        // the player). Matches every other SnappetUITests target.
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func section(_ t: String) -> XCUIElement { app.segmentedControls.buttons[t] }
    private func backIfDetail(_ marker: XCUIElement, _ label: String) {
        if marker.waitForExistence(timeout: 4) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        } else { snap("NOTREACHED-\(label)") }
    }

    func testFullWalkthrough() {
        snap("01-suite-home")
        app.tabBars.buttons["Apps"].tap()
        snap("02-app-library")

        // Enter the workout tracker (Button card).
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        sleep(1); snap("03-dashboard")

        // Sections. (History intentionally NOT visited here while empty — see DIAG below.)
        for s in ["Exercises", "Routines", "History", "Settings"] {
            if section(s).waitForExistence(timeout: 4) { section(s).tap(); sleep(1); snap("04-\(s)") }
        }

        // Browse → exercise detail (now reachable via Button row).
        section("Exercises").tap(); sleep(1)
        let exRow = app.buttons.matching(identifier: "exerciseRow").firstMatch
        if exRow.waitForExistence(timeout: 4) {
            exRow.tap(); sleep(1); snap("05-exercise-detail")
            XCTAssertTrue(app.staticTexts["Category"].waitForExistence(timeout: 4), "exercise detail should open")
            backIfDetail(app.staticTexts["Category"], "exercise-detail")
        }

        // Routine detail.
        section("Routines").tap(); sleep(1)
        let rRow = app.buttons.matching(identifier: "routineRow").firstMatch
        if rRow.waitForExistence(timeout: 4) {
            rRow.tap(); sleep(1); snap("06-routine-detail")
            XCTAssertTrue(app.buttons["Start Workout"].waitForExistence(timeout: 4), "routine detail should open")
            // Start the workout from the detail → drive player → finish.
            app.buttons["Start Workout"].tap(); sleep(2); snap("07-player")
            drivePlayerToDone(); sleep(2); snap("08-after-finish")
            let onDash = app.staticTexts["Day streak"].waitForExistence(timeout: 5)
                || app.staticTexts["Workouts"].waitForExistence(timeout: 2)
            XCTAssertTrue(onDash, "finishing a saved workout should land on the Dashboard")
        }

        // History now holds the finished session. NOTE: the history row is the one row kept as a
        // value-based NavigationLink (a Button there provably never fired), so it is not
        // XCUITest-tappable — we assert the list + saved session render, not the detail push.
        section("History").tap(); sleep(1); snap("09-history")
        XCTAssertTrue(app.staticTexts["5-Minute Mobility"].waitForExistence(timeout: 4)
            || app.cells.firstMatch.waitForExistence(timeout: 2),
            "the finished workout should appear in History")

        section("Settings").tap(); sleep(1); snap("11-settings")
    }

    private func drivePlayerToDone() {
        var snapped = false
        for i in 0..<40 {
            if app.buttons["Finish"].exists { snap("07b-done"); app.buttons["Finish"].tap(); return }
            if app.buttons["Skip rest"].exists { if !snapped { snap("07c-rest"); snapped = true }; app.buttons["Skip rest"].tap() }
            else if app.buttons["Complete & finish"].exists { app.buttons["Complete & finish"].tap() }
            else if app.buttons["Complete set"].exists { app.buttons["Complete set"].tap() }
            else if app.buttons["Skip exercise"].exists {
                app.buttons["Skip exercise"].tap()
                if app.buttons["Skip exercise"].exists { app.buttons["Skip exercise"].tap() }
            } else { break }
            usleep(600_000)
        }
        if app.buttons["End"].exists {
            app.buttons["End"].tap()
            if app.buttons["Save & exit"].waitForExistence(timeout: 2) { app.buttons["Save & exit"].tap() }
        }
    }
}
