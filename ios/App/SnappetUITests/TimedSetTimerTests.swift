import XCTest

/// UI coverage for the **timed-exercise hierarchy + live timer** (Quick Session redesign Phase 5; built on
/// workout-with-timer PR 2). Tapping **Timed** now opens the pick-or-create sheet (`PickTimedExerciseSheet`)
/// instead of dropping a bare unnamed row — selecting/creating a timed exercise drops a NAMED card whose
/// timed sets log underneath it via the shared `StopwatchView` timer.
///
/// Two tests:
/// - `testTimedSetCapturedWithTheLiveTimer`: pick a seeded suggestion → a named card → its "Add set" opens
///   the duration log sheet (Timer default) → Start/Stop captures a real elapsed → Add → the set row shows it.
/// - `testCreateCountDownTimedExerciseLandsAsNamedCardAndLogsASet`: Timed → Create new → name "10s hang"
///   + count-down + a preset chip → it lands as a NAMED card → log a set.
///
/// Uses the same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover
/// active session. Extract shots with `xcrun xcresulttool export attachments`.
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

    /// Open the timed pick-or-create sheet from the add-exercise dialog.
    private func openTimedPickSheet() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Timed exercise"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "the 'Timed exercise' dialog item should appear")
        opt.tap()
        XCTAssertTrue(app.buttons["timed.createNew"].waitForExistence(timeout: 6),
                      "the timed pick-or-create sheet should open with 'Create new' pinned")
    }

    /// Tap the "Add set" button for the most recently added exercise (robust to a tap occasionally
    /// double-firing under XCUITest — always log into the newest exercise).
    private func tapAddSetForLastExercise() {
        let adds = app.buttons.matching(identifier: "freeform.addSet")
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 4), "an Add set button should exist")
        adds.element(boundBy: adds.count - 1).tap()
    }

    func testTimedSetCapturedWithTheLiveTimer() {
        openFreeformPlayer()
        snap("01-freeform")

        // Timed → pick a seeded suggestion ("Free hold" — an open count-up, so the timer is a count-UP
        // dial whose frozen readout equals the value the set row shows) → a NAMED timed card drops.
        openTimedPickSheet()
        let suggestion = app.buttons["timed.suggested.seed.freehold"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "a seeded suggestion should be offered")
        suggestion.tap()
        sleep(1); snap("02-timed-added")
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2),
            "the picked timed exercise should land as a named card")

        tapAddSetForLastExercise()

        // The duration log sheet opens with the Timer|Manual toggle (default Timer).
        XCTAssertTrue(app.segmentedControls["logset.durationMode"].waitForExistence(timeout: 6),
                      "the duration log sheet should open with the Timer|Manual toggle")

        // Timer mode → the stopwatch is present (Dead hang is an open count-up → count-up readout).
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
        // SetMeasure rounding the set row will use, so the two must match exactly.
        let captured = app.staticTexts["stopwatch.elapsed"].label
        XCTAssertTrue(captured.range(of: "^[0-9]+:[0-9]{2}$", options: .regularExpression) != nil,
                      "the stopwatch should read a captured M:SS duration after Stop (got \(captured))")

        // The capture enables the Add commit. Save.
        let add = app.buttons["logset.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4) && add.isEnabled,
                      "capturing a duration should enable the Add button")
        snap("05-captured")
        add.tap()

        // The logged set row renders its duration via SetMeasure.summary ("M:SS").
        sleep(1); snap("06-logged")
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "a logged set row should appear")
        let shown = row.label.contains(captured)
            || row.staticTexts[captured].exists
            || app.staticTexts[captured].waitForExistence(timeout: 2)
        XCTAssertTrue(shown,
                      "the timed set row should show the captured duration (\(captured)); row label = \(row.label)")
    }

    /// Phase 5 acceptance: Timed → Create new → name "10s hang" + count-down + a preset chip → it lands as
    /// a NAMED card → log a set (the count-down dial captures the elapsed time held).
    func testCreateCountDownTimedExerciseLandsAsNamedCardAndLogsASet() {
        openFreeformPlayer()
        openTimedPickSheet()

        // Create new → the create-new form.
        app.buttons["timed.createNew"].tap()
        let nameField = app.textFields["timed.create.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "the create-new form should open with a name field")
        nameField.tap()
        nameField.typeText("10s hang")

        // Pre-fill from the 10s-hang preset chip (mode → max hang / count-down, work → 10s).
        let preset = app.buttons["timed.create.preset.maxhang"]
        XCTAssertTrue(preset.waitForExistence(timeout: 4), "the 10s-hang preset chip should exist")
        preset.tap()

        // The live total readout reflects the structure (a real, non-empty value).
        let total = app.staticTexts["timed.create.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 4), "a live Total readout should be shown")
        XCTAssertFalse(total.label.isEmpty, "the Total readout should show a value")
        snap("10-create-form")

        // Add to session → the sheet dismisses into a NAMED timed card.
        app.buttons["timed.create.add"].tap()
        sleep(1); snap("11-named-card")
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2),
            "creating a timed exercise should drop a named card")

        // Log a set: Add set → the duration sheet → time it (count-down dial → stopwatch.remaining) → Add.
        tapAddSetForLastExercise()
        XCTAssertTrue(app.segmentedControls["logset.durationMode"].waitForExistence(timeout: 6),
                      "the duration log sheet should open")
        let toggle = app.buttons["stopwatch.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the live stopwatch should be present")
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Stop"), "Start should flip to Stop")
        sleep(2)
        toggle.tap()
        XCTAssertTrue(waitForLabel(toggle, "Start"), "Stop should flip back to Start")

        let add = app.buttons["logset.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4) && add.isEnabled,
                      "a captured hold should enable Add")
        add.tap()
        sleep(1); snap("12-set-logged")
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "a logged set row should appear under the named timed card")
    }

    /// Wait until `el`'s accessibility label equals `expected` (the Start↔Stop flip).
    private func waitForLabel(_ el: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }
}
