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

        // Sections — text-labelled segments (#74). Settings is no longer a segment; it pushes
        // from the toolbar gear and is visited at the end (snap 11).
        // The "Exercises" segment is now "Library" (workout-redesign E3 — a discipline-spined library of
        // all workout types). The `browse` case id + the `workout.sectionPicker` a11y id are unchanged.
        for s in ["Library", "Routines", "History"] {
            if section(s).waitForExistence(timeout: 4) { section(s).tap(); sleep(1); snap("04-\(s)") }
        }

        // Library → exercise detail. The first library row is a strength exercise (the catalog leads), so
        // tapping it pushes the discipline-adaptive detail in its strength form (shows "Category").
        section("Library").tap(); sleep(1)
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
            // A2: the player shows a self-updating overall workout timer (distinct from the
            // per-set rest timer). It's a self-updating Text(timerInterval:), so we assert the
            // element exists rather than a specific value.
            XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 4)
                || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 1),
                "the player should show an overall workout timer")
            // A4: the live-metrics overlay (HR pill) is shown in the player. The sim has no
            // watch / HR source, so it renders its no-source state (we assert the overlay
            // element exists, not a bpm value — there is none in the simulator).
            XCTAssertTrue(app.otherElements["liveMetricsOverlay"].waitForExistence(timeout: 4)
                || app.staticTexts["liveMetricsOverlay"].waitForExistence(timeout: 1),
                "the player should show the live-metrics overlay (no-source state in the sim)")
            drivePlayerToDone(); sleep(2); snap("08-after-finish")
            // E1 (Pulse Pro): the dashboard's stat grid was replaced by a hero + type-aware Start CTA +
            // a recent-sessions feed. After a saved finish (history non-empty) the Start CTA always shows.
            let onDash = app.buttons["workout.dashboardStart"].waitForExistence(timeout: 5)
                || app.staticTexts["Active days this week"].waitForExistence(timeout: 2)
            XCTAssertTrue(onDash, "finishing a saved workout should land on the Dashboard")
        }

        // History now holds the finished session. NOTE: the history row is the one row kept as a
        // value-based NavigationLink (a Button there provably never fired), so it is not
        // XCUITest-tappable — we assert the list + saved session render, not the detail push.
        section("History").tap(); sleep(1); snap("09-history")
        XCTAssertTrue(app.staticTexts["5-Minute Mobility"].waitForExistence(timeout: 4)
            || app.cells.firstMatch.waitForExistence(timeout: 2),
            "the finished workout should appear in History")

        // Settings now pushes from the toolbar gear (#74) — it used to be a fifth segment.
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 4), "the Settings gear should be in the toolbar")
        gear.tap(); sleep(1); snap("11-settings")
        XCTAssertTrue(app.staticTexts["Heart-rate source"].waitForExistence(timeout: 4)
            || app.navigationBars["Settings"].waitForExistence(timeout: 2),
            "the gear should push the Settings screen")
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
