import XCTest

/// UI coverage for the **structured interval runner** (Quick Session redesign Phase 6). A `.repeaters` /
/// `.tabata` / `.emom` timed exercise's "Add set" presents the full-cover `StructuredTimedRunner` (a 3-2-1
/// lead-in → WORK/REST phases off the `IntervalSchedule`) instead of the simple Phase-5 stopwatch sheet.
///
/// The test creates a **Repeaters 7:3 × 6** exercise (Create new → the Repeaters preset chip) → a NAMED
/// card → its "Add set" opens the runner → asserts the big phase label (`intervalRunner.phase`) + the
/// count-down (`intervalRunner.timer`) are live → STOPs to reach the capture card → "Log set"
/// (`intervalRunner.logSet`) → a set row appears.
/// STOP (rather than running the full ~20 min protocol) keeps the test fast while still exercising the
/// lead-in → capture → commit funnel end to end. Device-only: audio/haptic cues + keep-awake.
@MainActor
final class StructuredIntervalRunnerTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
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

    private func openTimedPickSheet() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Timed exercise"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "the 'Timed exercise' dialog item should appear")
        opt.tap()
        XCTAssertTrue(app.buttons["timed.createNew"].waitForExistence(timeout: 6),
                      "the timed pick-or-create sheet should open")
    }

    private func tapAddSetForLastExercise() {
        let adds = app.buttons.matching(identifier: "freeform.addSet")
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 4), "an Add set button should exist")
        adds.element(boundBy: adds.count - 1).tap()
    }

    func testStructuredRunnerRunsLeadInThenCapturesAndLogs() {
        openFreeformPlayer()
        snap("01-freeform")

        // Timed → Create new → name it + tap the Repeaters preset chip (a structured 7:3 × 6 spec) →
        // Add to session. (The Create-new form is fully on-screen and deterministic; the seeded
        // suggestions list scrolls behind the sticky search field, so the preset chip is the robust path.)
        openTimedPickSheet()
        app.buttons["timed.createNew"].tap()
        let nameField = app.textFields["timed.create.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "the create-new form should open with a name field")
        nameField.tap()
        nameField.typeText("Repeaters")
        let preset = app.buttons["timed.create.preset.repeaters"]
        XCTAssertTrue(preset.waitForExistence(timeout: 4), "the Repeaters preset chip should exist")
        preset.tap()
        snap("02-create-repeaters")
        let addToSession = app.buttons["timed.create.add"]
        XCTAssertTrue(addToSession.waitForExistence(timeout: 4), "the 'Add to session' CTA should exist")
        addToSession.tap()
        sleep(1); snap("02b-repeaters-card")
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2),
            "the picked Repeaters exercise should land as a named card")

        // Add set → the structured interval runner cover opens (NOT the simple stopwatch sheet).
        tapAddSetForLastExercise()

        // The big phase label + the count-down timer are live (lead-in → "READY" then "WORK").
        let phase = app.staticTexts["intervalRunner.phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: 6),
                      "the structured runner should show the big phase label")
        let timer = app.staticTexts["intervalRunner.timer"]
        XCTAssertTrue(timer.waitForExistence(timeout: 4),
                      "the structured runner should show the draining count-down timer")
        XCTAssertFalse(timer.label.isEmpty, "the count-down timer should read a value")
        snap("03-runner-leadin")

        // Let the 3 s lead-in elapse and a beat of the first WORK phase run, so the captured
        // time-under-tension is a real, non-zero value before we STOP.
        sleep(5)
        snap("03b-runner-work")

        // STOP → the capture card (pre-filled with the time-under-tension + completed reps·sets).
        let stop = app.buttons["intervalRunner.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 4), "STOP should be available while running")
        stop.tap()

        let logSet = app.buttons["intervalRunner.logSet"]
        XCTAssertTrue(logSet.waitForExistence(timeout: 5),
                      "STOP should reveal the capture card with a 'Log set' commit")
        snap("04-capture-card")
        logSet.tap()

        // A logged set row appears under the named timed card.
        sleep(1); snap("05-logged")
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6),
                      "logging from the runner should drop a set row under the named card")
    }
}
