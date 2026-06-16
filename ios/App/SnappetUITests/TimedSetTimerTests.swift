import XCTest

/// UI coverage for the **timed-set live timer** (workout-with-timer PR 2): the freeform `LogSetSheet`'s
/// `.duration` case can now time a hold with the shared `StopwatchView` (PR 1) instead of only typing
/// Min/Sec. Drives the real path — Quick Start → add a Timed exercise → open the log sheet → Timer mode
/// (the default) → Start, let it run, Stop captures the elapsed → Add → assert the logged set row shows a
/// duration. Extract shots with `xcrun xcresulttool export attachments`.
///
/// Uses the same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover
/// active session.
final class TimedSetTimerTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Apps → Workout dashboard → Quick Start, landing in the routineless freeform player.
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

    private func addExerciseMenu(_ item: String) {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons[item]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "menu item \(item) should appear")
        opt.tap()
    }

    /// Tap the "Add set" button for the most recently added exercise (robust to a SwiftUI `Menu` tap
    /// occasionally double-firing under XCUITest — always log into the newest exercise).
    private func tapAddSetForLastExercise() {
        let adds = app.buttons.matching(identifier: "freeform.addSet")
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 4), "an Add set button should exist")
        adds.element(boundBy: adds.count - 1).tap()
    }

    func testTimedSetCapturedWithTheLiveTimer() {
        openFreeformPlayer()
        snap("01-freeform")

        // Add a Timed exercise and open its log sheet.
        addExerciseMenu("Timed exercise")
        sleep(1); snap("02-timed-added")
        tapAddSetForLastExercise()

        // The sheet defaults to Timer mode → the stopwatch is present; the Manual Min/Sec fields are not.
        let toggle = app.buttons["stopwatch.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "the duration sheet should default to the live stopwatch (Timer mode)")
        XCTAssertEqual(toggle.label, "Start", "the stopwatch should start in its idle 'Start' state")
        XCTAssertFalse(app.textFields["Min"].exists,
                       "Manual Min/Sec fields should be hidden while Timer mode is selected")
        snap("03-timer-idle")

        // Start → let it run a beat → Stop captures the elapsed seconds.
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Stop"), "tapping Start should flip the control to 'Stop'")
        sleep(2)   // wall-clock elapsed so the capture is a real, non-zero duration
        snap("04-timer-running")
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Start"), "tapping Stop should flip the control back to 'Start'")
        // Read the FROZEN readout after Stop: it renders the captured elapsed through the same
        // SetMeasure rounding the set row will use, so the two must match exactly (reading mid-run could
        // roll to the next second between the read and the tap). This exact M:SS must land in the row.
        let captured = app.staticTexts["stopwatch.elapsed"].label
        XCTAssertTrue(captured.range(of: "^[0-9]+:[0-9]{2}$", options: .regularExpression) != nil,
                      "the stopwatch should read a captured M:SS duration after Stop (got \(captured))")

        // The capture filled the underlying state → the Add commit is now enabled. Save.
        let add = app.buttons["logset.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4) && add.isEnabled,
                      "capturing a duration should enable the Add button")
        snap("05-captured")
        add.tap()

        // The logged set row renders its duration via SetMeasure.summary ("M:SS"). Assert on the actual
        // `freeform.setRow` — NOT the always-running `overallWorkoutTimer` (which also reads M:SS, so a
        // loose any-static-text match would pass even if nothing were saved). The captured duration must
        // be the one persisted into the row, so the test fails if the live capture is dropped.
        sleep(1); snap("06-logged")
        let row = app.cells["freeform.setRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "a logged set row should appear")
        // The captured M:SS must be inside the row — either as a descendant static text, or merged into
        // the row's own coalesced label (SwiftUI does one or the other for a multi-Text List row). Both
        // forms read `captured` from `freeform.setRow`, never from `overallWorkoutTimer`.
        let durationInRow = row.staticTexts[captured].waitForExistence(timeout: 4)
            || (row.label.contains(captured))
        XCTAssertTrue(durationInRow,
                      "the timed set row should show the captured duration (\(captured)), not just the overall timer")
    }

    /// Wait until `el`'s accessibility label equals `expected` (the Start↔Stop flip).
    private func waitForLabel(_ el: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }
}
