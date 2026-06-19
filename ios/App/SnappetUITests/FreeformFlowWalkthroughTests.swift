import XCTest

/// Screenshot-capturing walkthrough of the **freeform / ad-hoc** session flow (dynamic-sessions
/// D3/D5): Quick Start → a routineless `FreeformPlayerView` → add Climbing / Lifting / Timed
/// exercises and log a set/attempt of each → Finish. Asserts the kind-adaptive `LogSetSheet` and the
/// per-set summary rows (`SetMeasure.summary`) render for every `SetKind`. Extract shots with
/// `xcrun xcresulttool export attachments`.
///
/// (The History→detail push is a value-based NavigationLink that is deliberately not XCUITest-tappable
/// — see HistorySectionView — so SessionDetailView's per-set tiles are covered by unit tests +
/// `SetMeasureTests`, not driven here.)
final class FreeformFlowWalkthroughTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true   // keep capturing screenshots even if one assert trips
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func addExerciseMenu(_ item: String) {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons[item]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "menu item \(item) should appear")
        opt.tap()
    }

    /// Tap the "Add set/attempt" button for the most recently added exercise (the last one in the
    /// list). Robust to SwiftUI `Menu` taps occasionally double-firing under XCUITest (which can add a
    /// duplicate section) — we always log into the newest exercise of the kind we just added.
    private func tapAddSetForLastExercise() {
        let adds = app.buttons.matching(identifier: "freeform.addSet")
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 4), "an Add set/attempt button should exist")
        let n = adds.count
        let button = adds.element(boundBy: n - 1)
        // The newest exercise auto-scrolls to centre as it's added; depending on the exact resting
        // position its Add button can land in a transiently non-hittable strip (a tap on a non-hittable
        // visible element throws). A nudge-scroll settles the list and brings it fully into the hittable
        // area; a coordinate tap is the fallback if `isHittable` still lags the layout.
        if !button.isHittable { app.swipeUp() }
        if button.isHittable {
            button.tap()
        } else {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    /// Add a climb through the "Add a climb" sheet (Quick Session redesign Phase 1): pick a grade rung,
    /// type the name, then "Add & log first attempt" (auto-opens the inline outcome strip on the card).
    private func addClimbAndLog(grade: String, name: String, outcome: String) {
        let typePicker = app.segmentedControls["addClimb.type"]
        XCTAssertTrue(typePicker.waitForExistence(timeout: 6), "the Add-a-climb sheet should present a TYPE picker")
        let rung = app.buttons["addClimb.rung.\(grade)"]
        XCTAssertTrue(rung.waitForExistence(timeout: 4), "the grade rail should offer the \(grade) rung")
        rung.tap()
        typeIn(app.textFields["addClimb.name"], name)
        app.buttons["addClimb.addAndLog"].tap()
        let outcomeButton = app.buttons["freeform.outcome.\(outcome)"]
        XCTAssertTrue(outcomeButton.waitForExistence(timeout: 6),
                      "the new climb card should auto-open its inline outcome strip")
        outcomeButton.tap()
    }

    func testFreeformWalkthrough() {
        // 1 — Suite home → App Library → WorkoutTracker dashboard.
        snap("01-suite-home")
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 6))
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        sleep(1); snap("02-dashboard")

        // 2 — Quick Start → the freeform player ("Quick session").
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5), "Quick Start should be on the dashboard")
        quick.tap()
        sleep(1); snap("03-freeform-empty")
        XCTAssertTrue(app.staticTexts["Quick session"].waitForExistence(timeout: 5)
            || app.navigationBars["Quick session"].waitForExistence(timeout: 2),
            "the freeform player should open titled 'Quick session'")

        // 3 — Climbing → the "Add a climb" sheet (Quick Session redesign): pick a V4 rung, name "Cave",
        // "Add & log first attempt" → pick the Sent outcome. The grade is captured ONCE on the card.
        addExerciseMenu("Climbing")
        snap("04-add-climb-sheet")
        addClimbAndLog(grade: "V4", name: "Cave", outcome: "sent")
        sleep(1); snap("05-climb-logged")
        // The climb card shows the grade pill (V4); the attempt row shows the outcome (Sent), not the grade.
        // `.firstMatch` because a SwiftUI confirmationDialog/Form button tap can occasionally double-fire
        // under XCUITest (the same hazard `tapAddSetForLastExercise` guards against), creating more than
        // one identical V4 climb — any of which proves the grade was captured on the card.
        let pill = app.staticTexts.matching(identifier: "freeform.gradePill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 4), "the climb card should show its grade pill")
        XCTAssertEqual(pill.label, "V4", "the grade pill should read the climb's grade (V4)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sent'")).firstMatch
            .waitForExistence(timeout: 4), "the attempt row should read its outcome (Sent)")

        // 4 — Lifting → pick the first exercise → log 8 reps × 60. (We deliberately DON'T use the
        // search field: iOS 26's `.searchable` moves search to the bottom and hides the nav bar's
        // "Add" commit button while active. Any lifting exercise verifies reps×weight rendering.)
        addExerciseMenu("Lifting exercise")
        sleep(1); snap("06b-picker")
        // Tap the first exercise ROW (not the tiny selection circle): every row's subtitle ends in a
        // level word, which the circle button and the climb row behind the sheet don't have.
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker should list exercises")
        let liftName = row.label
        row.tap()
        sleep(1); snap("06d-picker-selected")
        // Commit button reads "Add (N)" once a row is selected; it's the only nav-bar button whose
        // label begins with "Add" (the player's nav bar behind the sheet has none).
        let addLift = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addLift.waitForExistence(timeout: 4), "the picker's Add commit button should appear")
        addLift.tap()
        print("FREEFORM-VERIFY picked lifting exercise: \(liftName)")
        sleep(1); snap("07-lifting-added")
        tapAddSetForLastExercise()
        typeIn(app.textFields["logset.reps"], "8")
        typeIn(app.textFields["logset.weight"], "60")
        snap("08-lift-sheet")
        app.buttons["logset.add"].tap()
        sleep(1); snap("09-lift-logged")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'kg'")).firstMatch
            .waitForExistence(timeout: 4), "the lifting row should read its weight (8 × 60 kg)")

        // 5 — Timed → log 0:45. "Timed exercise" now opens the Phase-5 pick-or-create sheet; pick the
        // seeded "Free hold" suggestion (an open count-up, the simple LogSetSheet path) to drop a NAMED
        // timed card, then Add set → switch to Manual to type an exact value (the live-timer path is
        // covered by TimedSetTimerTests).
        addExerciseMenu("Timed exercise")
        let freeHold = app.buttons["timed.suggested.seed.freehold"]
        XCTAssertTrue(freeHold.waitForExistence(timeout: 5), "the pick sheet should offer the Free hold suggestion")
        freeHold.tap()
        sleep(1); snap("10-timed-added")
        tapAddSetForLastExercise()
        let manual = app.segmentedControls.buttons["Manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 4), "the duration sheet should offer a Manual mode")
        manual.tap()
        typeIn(app.textFields["Min"], "0")
        typeIn(app.textFields["Sec"], "45")
        snap("11-timed-sheet")
        app.buttons["logset.add"].tap()
        sleep(1); snap("12-timed-logged")
        XCTAssertTrue(app.staticTexts["0:45"].waitForExistence(timeout: 4)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0:45'")).firstMatch.exists,
            "the timed row should read 0:45")

        // 6 — Finish → completion summary (#158 §D) → Done saves & exits; the session is in History.
        let finish = app.buttons["freeform.finish"]
        if !finish.exists { app.swipeUp() }
        XCTAssertTrue(finish.waitForExistence(timeout: 4), "Finish workout should be available")
        finish.tap()
        let done = app.buttons["freeform.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the completion summary should appear")
        snap("12b-summary")
        done.tap()
        sleep(2); snap("13-after-finish")

        if app.segmentedControls.buttons["History"].waitForExistence(timeout: 4) {
            app.segmentedControls.buttons["History"].tap(); sleep(1); snap("14-history")
            XCTAssertTrue(app.buttons["historyRow"].firstMatch.waitForExistence(timeout: 4)
                || app.cells.firstMatch.waitForExistence(timeout: 2),
                "the finished freeform session should appear in History")
        }
    }

    /// Save-as-routine (workout-redesign E5): Quick Start → log a lift → Finish → the completion summary's
    /// coral "Save as routine" opens the PRE-FILLED routine editor (the converter's actuals→prescription
    /// draft) → review → Save → the new routine appears in Routines and can be started.
    func testSaveQuickSessionAsRoutine() {
        // 1 — Suite home → WorkoutTracker dashboard → Quick Start.
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 6))
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5), "Quick Start should be on the dashboard")
        quick.tap()
        snap("e5-01-freeform-empty")

        // 2 — Lifting → pick the first exercise → log 8 × 60 (one completed set is enough to convert).
        addExerciseMenu("Lifting exercise")
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker should list exercises")
        row.tap()
        let addLift = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addLift.waitForExistence(timeout: 4), "the picker's Add commit button should appear")
        addLift.tap()
        tapAddSetForLastExercise()
        typeIn(app.textFields["logset.reps"], "8")
        typeIn(app.textFields["logset.weight"], "60")
        app.buttons["logset.add"].tap()
        sleep(1); snap("e5-02-logged")

        // 3 — Finish → the completion summary; the coral "Save as routine" affordance is present.
        let finish = app.buttons["freeform.finish"]
        if !finish.exists { app.swipeUp() }
        XCTAssertTrue(finish.waitForExistence(timeout: 4), "Finish should be available")
        finish.tap()
        let saveAsRoutine = app.buttons["freeform.saveAsRoutine"]
        XCTAssertTrue(saveAsRoutine.waitForExistence(timeout: 5),
                      "the completion summary should offer 'Save as routine' (a logged session converts)")
        snap("e5-03-summary-with-save")
        saveAsRoutine.tap()

        // 4 — The PRE-FILLED routine editor opens: name suggested, ≥ 1 block already present (no empty
        // editor — the converter pre-filled it for review). Rename it, then Save.
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "the routine editor should open pre-filled")
        // The editor's Save is enabled only when the name is non-empty AND there's ≥ 1 block → its enabled
        // state proves the converter pre-filled at least one block.
        let saveRoutine = app.navigationBars.buttons["Save"]
        XCTAssertTrue(saveRoutine.waitForExistence(timeout: 4), "the editor should offer Save")
        XCTAssertTrue(saveRoutine.isEnabled,
                      "Save is enabled → the editor was pre-filled with a name + at least one block")
        nameField.tap()
        // Clear any suggested text and type a distinctive name we can find in the list.
        nameField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        nameField.typeText("My Saved Routine")
        snap("e5-04-editor-prefilled")
        saveRoutine.tap()

        // 5 — Back on the summary; tap Done to finish & exit, then go to Routines: the new routine is there.
        let done = app.buttons["freeform.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the summary should still be showing after the editor")
        done.tap()
        sleep(1)
        let routinesTab = app.segmentedControls.buttons["Routines"]
        XCTAssertTrue(routinesTab.waitForExistence(timeout: 5), "the Routines section should be reachable")
        routinesTab.tap()
        sleep(1); snap("e5-05-routines")
        XCTAssertTrue(app.staticTexts["My Saved Routine"].waitForExistence(timeout: 5)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'My Saved Routine'")).firstMatch
                .waitForExistence(timeout: 2),
            "the saved routine should appear in Routines")
    }
}
