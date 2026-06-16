import XCTest

/// UI coverage for the **per-attempt climb timer** (workout-with-timer PR 4): in the freeform player's
/// climb-attempt log sheet (`LogSetSheet` `.climbAttempt`), the user can OPTIONALLY time how long an
/// attempt took with the shared `StopwatchView` (PR 1, count-up). The captured seconds are stored in the
/// existing `SetLog.durationSec` (unused for `.climbAttempt` until now — no model change) and appended to
/// the climb set's summary row ("V4 · Sent · 0:02"). This is the climb-side analogue of PR 2's timed set.
///
/// Drives the real path — Quick Start → add a "Climbing" exercise → Add attempt → enable the timer
/// (`logset.climbTimerToggle`, off by default) → `stopwatch.toggle` Start, let it run, Stop captures the
/// elapsed → set grade "V4" → Add → assert a `freeform.setRow` shows BOTH the grade and the captured
/// M:SS. The timer toggle defaults off, so this exercises the opt-in path explicitly.
///
/// Same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover active
/// session. Extract shots with `xcrun xcresulttool export attachments`.
final class ClimbAttemptTimerTests: XCTestCase {
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

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    func testClimbAttemptTimedWithTheLiveStopwatch() {
        openFreeformPlayer()
        snap("01-freeform")

        // Add a Climbing exercise and open its attempt log sheet.
        addExerciseMenu("Climbing")
        sleep(1); snap("02-climbing-added")
        tapAddSetForLastExercise()

        // The climb log sheet opens with the grade field. Assert it opened first, so a sheet-didn't-open
        // failure is distinguishable from a missing timer control.
        let grade = app.textFields["logset.grade"]
        XCTAssertTrue(grade.waitForExistence(timeout: 6), "the climb attempt log sheet should open")

        // The per-attempt timer is OPT-IN: the stopwatch is hidden until the toggle is enabled. Confirm it
        // is off by default (no stopwatch yet), then enable it.
        XCTAssertFalse(app.buttons["stopwatch.toggle"].exists,
                       "the per-attempt timer should be OFF by default (stopwatch hidden)")
        // A SwiftUI `Toggle` surfaces as a `.switch`; query type-agnostically by id so the test doesn't
        // hinge on the exact element type the Form row reports it as.
        let timerToggle = app.descendants(matching: .any).matching(identifier: "logset.climbTimerToggle").firstMatch
        XCTAssertTrue(timerToggle.waitForExistence(timeout: 4),
                      "the climb sheet should offer a 'Time the attempt' toggle")
        timerToggle.tap()
        snap("03-timer-enabled")

        // Enabling the toggle reveals the count-up stopwatch.
        let toggle = app.buttons["stopwatch.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "enabling the timer should reveal the live stopwatch")
        XCTAssertEqual(toggle.label, "Start", "the stopwatch should start in its idle 'Start' state")

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

        // Set the grade so the attempt is loggable and the row carries a distinctive value.
        typeIn(grade, "V4")
        snap("05-captured")

        // Add commits the attempt: grade + the timed capture (stored in durationSec).
        let add = app.buttons["logset.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4) && add.isEnabled,
                      "a graded attempt should enable the Add button")
        add.tap()

        // The logged climb row renders via SetMeasure.summary — "V4 · Sent · M:SS" (the appended duration).
        // `freeform.setRow` is the row's content HStack (a static-text / container element, NOT a List
        // cell), so query it type-agnostically. Assert BOTH the grade and the captured M:SS appear in the
        // same row: the grade ("V4") is distinctive and the appended duration proves the live capture was
        // persisted into durationSec.
        sleep(1); snap("06-logged")
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "a logged climb set row should appear")
        XCTAssertTrue(row.label.contains("V4"),
                      "the climb row should show the grade (V4); row label = \(row.label)")
        let showsDuration = row.label.contains(captured)
            || row.staticTexts[captured].exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "V4 · Sent · \(captured)"))
                .firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(showsDuration,
                      "the climb row should show the captured attempt time (\(captured)); row label = \(row.label)")
    }

    /// Wait until `el`'s accessibility label equals `expected` (the Start↔Stop flip).
    private func waitForLabel(_ el: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }
}
