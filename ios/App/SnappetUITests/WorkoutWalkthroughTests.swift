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
            // A4 live metrics in the PAGER player (prompt 119 deleted the guided player and its
            // always-on "liveMetricsOverlay"): the pager's HR chip (freeform.hrChip) is hidden
            // until a live sample arrives, so on the sim (no HR source) there is no live-metrics
            // element — assert the always-rendered player chrome instead.
            XCTAssertTrue(app.buttons["pauseWorkout"].waitForExistence(timeout: 4),
                "the player should show its pause control")
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

    /// Drive the (single) pager player to a saved finish. A routine now plays through the same
    /// grow-as-you-go pager as Quick Session, so we log one effort (so the session saves — History
    /// needs a completed set), dismiss any auto-started rest, then Finish → the type-adaptive summary →
    /// Done. The first starter routine opens on a strength exercise (the coral "Log set"); a climb
    /// starter would open on the outcome grid instead, so we try both.
    private func drivePlayerToDone() {
        let log = app.buttons["freeform.quickLog"]
        if log.waitForExistence(timeout: 4) {
            log.tap()
        } else if app.buttons["freeform.outcome.sent"].waitForExistence(timeout: 1) {
            app.buttons["freeform.outcome.sent"].tap()   // a climb-discipline starter
        } else if app.buttons["freeform.addSet"].waitForExistence(timeout: 1) {
            // A TIMED page — the first routine row is the "5-Minute Mobility" starter (digits sort
            // first), whose holds are simple count-downs: Add set → the duration sheet's live
            // stopwatch → Start, a beat, Stop → Add commits the captured hold (the
            // TimedSetTimerTests pattern). Without a completed set, Finish silently DISCARDS
            // (finishTapped's zero-set guard) and History stays empty.
            app.buttons.matching(identifier: "freeform.addSet").firstMatch.tap()
            let toggle = app.buttons["stopwatch.toggle"]
            if toggle.waitForExistence(timeout: 5) {
                toggle.tap()          // Start
                sleep(2)
                toggle.tap()          // Stop → captures the elapsed hold
            }
            let add = app.buttons["logset.add"]
            if add.waitForExistence(timeout: 4) && add.isEnabled { add.tap() }
        }
        usleep(600_000); snap("07b-logged")
        // A log can auto-start a rest count-down on the page; clear it so the command bar is free.
        if app.buttons["freeform.restDismiss"].exists { app.buttons["freeform.restDismiss"].tap() }
        // The command bar's always-available Finish → the completion summary.
        let finish = app.buttons["freeform.finish"]
        if finish.waitForExistence(timeout: 4) { finish.tap() }
        snap("07c-summary")
        // Done saves the workout (a set was logged) and dismisses the cover back to the dashboard.
        let done = app.buttons["freeform.done"]
        if done.waitForExistence(timeout: 4) { done.tap() }
    }
}
