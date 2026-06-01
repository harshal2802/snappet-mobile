import XCTest

/// End-to-end walkthrough of the Pomodoro mini-app: open it from the App Library, exercise the
/// start/pause/reset controls, open the History screen, and confirm a settings change persists
/// across a relaunch. Uses the stable `accessibilityIdentifier`s declared on the Pomodoro views.
final class PomodoroUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Open the App Library and tap into the Pomodoro module.
    private func openPomodoro(_ app: XCUIApplication) {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.pomodoro"]
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have the Pomodoro card")
        var tries = 0
        while !card.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    func testTimerControlsAndHistory() {
        let app = XCUIApplication()
        app.launch()
        openPomodoro(app)

        // Timer label and controls are present.
        XCTAssertTrue(app.otherElements["pomodoro.timeRemaining"].waitForExistence(timeout: 6)
                      || app.staticTexts["pomodoro.timeRemaining"].exists,
                      "Timer label should be visible")

        let start = app.buttons["pomodoro.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 6), "Start button should exist")
        start.tap()

        // Starting swaps Start → Pause.
        let pause = app.buttons["pomodoro.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 4), "Pause button should appear after starting")
        pause.tap()

        // Reset returns to an idle (Start-visible) state.
        app.buttons["pomodoro.reset"].tap()
        XCTAssertTrue(app.buttons["pomodoro.start"].waitForExistence(timeout: 4),
                      "Reset should return the timer to a startable state")

        // Open History via the toolbar link and confirm the screen loads.
        let history = app.buttons["pomodoro.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 4), "History link should exist")
        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 6),
                      "History screen should appear")

        // Back out to the root.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["pomodoro.start"].waitForExistence(timeout: 6),
                      "Should return to the Pomodoro root")
    }

    func testSettingsPersistAcrossRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openPomodoro(app)

        // Open settings and bump the focus length up one step.
        let settings = app.buttons["pomodoro.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6), "Settings button should exist")
        settings.tap()

        let focusStepper = app.steppers["pomodoro.focusStepper"]
        XCTAssertTrue(focusStepper.waitForExistence(timeout: 6), "Focus stepper should appear")
        focusStepper.buttons.element(boundBy: 1).tap() // increment

        // The focus length is shown as a "<n> min" label inside the stepper's row; that text
        // reflects the persisted @AppStorage value, so capturing it is a meaningful check.
        let labelAfterChange = focusLengthLabel(in: app)
        XCTAssertNotNil(labelAfterChange, "Focus length label should be readable after incrementing")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }

        app.terminate()
        app.launch()
        openPomodoro(app)
        app.buttons["pomodoro.settings"].tap()

        let reopened = app.steppers["pomodoro.focusStepper"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 6), "Focus stepper should reappear")
        // The persisted @AppStorage value should survive the relaunch.
        let labelAfterRelaunch = focusLengthLabel(in: app)
        XCTAssertEqual(labelAfterChange, labelAfterRelaunch,
                       "Focus length should persist across relaunch")
    }

    /// The identified "<n> min" value text in the focus settings row (reflects the persisted value).
    private func focusLengthLabel(in app: XCUIApplication) -> String? {
        let label = app.staticTexts["pomodoro.focusValue"]
        guard label.waitForExistence(timeout: 4) else { return nil }
        return label.label
    }
}
