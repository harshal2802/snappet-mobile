import XCTest

/// UI coverage for the **timed climb attempt** under the climb-first hierarchy. The card footer's
/// **"Timed attempt"** button now opens the full-screen `TimedAttemptCover` (Quick Session redesign
/// Phase 2): a dark glass FOCUS surface whose hero timer (`timedAttempt.timer`) ticks off the wall clock
/// and auto-starts on appear. A full-width STOP (`timedAttempt.stop`) freezes it and reveals a 2×2 outcome
/// grid; picking Send (`timedAttempt.outcome.sent`) commits the attempt with the captured duration into
/// `SetLog.durationSec` and dismisses. The grade is captured ONCE on the climb card, so the cover only
/// times duration + picks an outcome — and the per-attempt row reads the outcome + the captured M:SS (NOT
/// the grade — `SetMeasure.attemptRow`).
///
/// Drives the real path — Quick Start → tap Climbing → Add-a-climb sheet → pick a V4 rung → "Add climb"
/// (card collapsed) → expand → "Timed attempt" → the cover auto-starts; let it run → STOP → pick Send →
/// assert a `freeform.setRow` attempt row appears under the card.
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

    /// Add a climb through the Add-a-climb sheet: pick the given grade rung, then tap "Add climb" (the
    /// card lands collapsed with no attempt yet — the path this test then drives via the footer).
    private func addClimb(grade: String) {
        addExerciseMenu("Climbing")
        let typePicker = app.segmentedControls["addClimb.type"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 6), "the Add-a-climb sheet should present a TYPE picker")
        let rung = app.buttons["addClimb.rung.\(grade)"]
        XCTAssertTrue(rung.waitForExistence(timeout: 4), "the grade rail should offer the \(grade) rung")
        rung.tap()
        app.buttons["addClimb.add"].tap()
    }

    func testTimedAttemptCapturesDurationWithTheLiveCover() {
        openFreeformPlayer()
        snap("01-freeform")

        // Add a V4 climb (card lands collapsed).
        addClimb(grade: "V4")
        sleep(1); snap("02-climb-added")

        // Expand the card to reach its footer (the new card may already be expanded; expand only if the
        // footer's "Timed attempt" isn't already visible).
        let timed = app.buttons["freeform.timedAttempt"]
        if !timed.waitForExistence(timeout: 3) {
            app.buttons["freeform.climbExpand"].firstMatch.tap()
        }
        XCTAssertTrue(timed.waitForExistence(timeout: 5),
                      "an expanded climb card should offer a 'Timed attempt' footer button")
        timed.tap()

        // The FOCUS cover auto-starts the wall-clock timer on appear — no Start tap. Wait for the hero
        // timer, let it run a beat, then STOP captures the elapsed and reveals the outcome grid.
        let timer = app.staticTexts["timedAttempt.timer"]
        XCTAssertTrue(timer.waitForExistence(timeout: 6),
                      "the timed-attempt cover should host an auto-started hero timer")
        sleep(2)   // wall-clock elapsed so the capture is a real, non-zero duration
        snap("03-timer-running")

        let stop = app.buttons["timedAttempt.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 4), "the running cover should offer a STOP button")
        stop.tap()

        // After STOP the frozen readout renders the captured elapsed through the same SetMeasure rounding
        // the attempt row will use, so the two must match exactly.
        XCTAssertTrue(timer.waitForExistence(timeout: 4))
        let captured = timer.label
        XCTAssertTrue(captured.range(of: "^[0-9]+:[0-9]{2}$", options: .regularExpression) != nil,
                      "the cover timer should read a captured M:SS duration after Stop (got \(captured))")
        snap("04-captured")

        // Pick the Send outcome → the timed attempt logs with the captured duration and the cover dismisses.
        let sent = app.buttons["timedAttempt.outcome.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 4), "the stopped cover should reveal a Send outcome")
        sent.tap()
        sleep(1); snap("05-logged")

        // The logged attempt row renders via SetMeasure.attemptRow — "Sent · M:SS" (the captured
        // duration, NOT the grade). Assert a `freeform.setRow` exists and one leaf static text carries the
        // captured time, proving the live capture was persisted into durationSec.
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "a logged climb attempt row should appear")
        let summary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", captured)).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6),
                      "the attempt row should show the captured attempt time (\(captured))")
    }
}
