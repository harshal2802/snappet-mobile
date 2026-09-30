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

    /// Prompt 140: the Max hangs preset fills every field, the summary reads back in plain English, and
    /// rest between sets (fixed at 3 min before) is editable.
    func testMaxHangsPresetAndEditableRestBetweenSets() {
        openFreeformPlayer()
        openTimedPickSheet()
        app.buttons["timed.createNew"].tap()
        let preset = app.buttons["timed.create.preset.maxhangs"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "the Max hangs preset chip should exist")
        preset.tap()
        let summary = app.staticTexts["protocol.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 4))
        XCTAssertTrue(summary.label.hasPrefix("3 sets × 3 hangs of 7 s · 2 min between hangs · 4 min between sets"),
                      summary.label)
        let setRestPlus = app.buttons["timed.create.setRest.plus"]
        for _ in 0..<4 where !setRestPlus.exists { app.swipeUp() }
        XCTAssertTrue(setRestPlus.waitForExistence(timeout: 4), "rest between sets is editable")
        setRestPlus.tap()
        XCTAssertTrue(summary.label.contains("4:15 between sets"), summary.label)
        snap("protocol-editor-maxhangs")
        app.buttons["timed.create.add"].tap()
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2),
            "the protocol lands as a named card")
    }

    /// Prompt 141: a Contact rep waits for DONE (the protocol clock doesn't run on without you), then the
    /// rest starts; stopping logs the tap-done time.
    func testContactRepWaitsForDoneThenRests() {
        openFreeformPlayer()
        openTimedPickSheet()
        app.buttons["timed.createNew"].tap()
        let preset = app.buttons["timed.create.preset.contact"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5), "the Contact preset chip should exist")
        preset.tap()
        XCTAssertTrue(app.staticTexts["protocol.summary"].label.contains("each until you tap done"),
                      app.staticTexts["protocol.summary"].label)
        app.buttons["timed.create.add"].tap()
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2))
        tapAddSetForLastExercise()

        // After the 5 s get-ready, rep 1 waits for DONE — well past any fixed hang length.
        let done = app.buttons["intervalRunner.repDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "a tap-done rep shows DONE")
        XCTAssertEqual(app.staticTexts["intervalRunner.phase"].label, "GO")
        sleep(3)
        XCTAssertTrue(done.exists, "the rep never times out on its own")
        snap("contact-rep")
        done.tap()

        // The 30 s rest runs next.
        let phase = app.staticTexts["intervalRunner.phase"]
        let deadline = Date().addingTimeInterval(4)
        while phase.label != "REST", Date() < deadline { usleep(200_000) }
        XCTAssertEqual(phase.label, "REST")
        XCTAssertTrue(app.staticTexts["intervalRunner.timer"].exists, "rests keep the count-down ring")

        app.buttons["intervalRunner.stop"].tap()
        let tut = app.staticTexts["intervalRunner.captureTUT"]
        XCTAssertTrue(tut.waitForExistence(timeout: 4))
        XCTAssertNotEqual(tut.label, "0:00", "the tap-done rep's time is logged")
    }

    /// Prompt 142: one-hand alternating with added weight — the summary says so, and the runner shows the
    /// hand and the load on every hang.
    func testOneHandWithAddedLoadShowsHandAndLoad() {
        openFreeformPlayer()
        openTimedPickSheet()
        app.buttons["timed.createNew"].tap()
        let preset = app.buttons["timed.create.preset.maxhangs"]
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()

        let added = app.buttons["+ Added"]
        for _ in 0..<5 where !added.exists { app.swipeUp() }
        XCTAssertTrue(added.waitForExistence(timeout: 4), "the Load section offers + Added")
        added.tap()
        let plus = app.buttons["protocol.load.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 4))
        plus.tap(); plus.tap(); plus.tap(); plus.tap()   // 4 × 2.5 kg default step = 10 kg
        let oneHand = app.buttons["One hand"]
        for _ in 0..<3 where !oneHand.exists { app.swipeUp() }
        oneHand.tap()

        let summary = app.staticTexts["protocol.summary"]
        XCTAssertTrue(summary.label.contains("each hand, alternating"), summary.label)
        XCTAssertTrue(summary.label.contains("+10 kg"), summary.label)
        snap("protocol-one-hand-load")
        app.buttons["timed.create.add"].tap()
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2))
        tapAddSetForLastExercise()

        // During get-ready: which hand comes first. Then the hang shows LEFT and the load.
        XCTAssertTrue(app.staticTexts["intervalRunner.nextHand"].waitForExistence(timeout: 6))
        let hand = app.staticTexts["intervalRunner.hand"]
        XCTAssertTrue(hand.waitForExistence(timeout: 10), "the hang shows which hand")
        XCTAssertTrue(hand.label.contains("LEFT"), hand.label)
        XCTAssertTrue(app.otherElements["intervalRunner.load"].exists || app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '+10 kg'")).firstMatch.exists, "the load shows on the hang")
        snap("runner-one-hand-load")
        app.buttons["intervalRunner.stop"].tap()
    }
}
