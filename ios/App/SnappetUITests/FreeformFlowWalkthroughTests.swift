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
        adds.element(boundBy: n - 1).tap()
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    /// Climbs are added immediately now (#158 §C — no blocking prompt); the section header is an inline
    /// `freeform.climbName` TextField defaulting to "Climbing". Rename it in place (clear + type + submit).
    private func nameThisClimb(_ name: String) {
        let field = app.textFields["freeform.climbName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the climb section should have an inline name field")
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText("\(name)\n")
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

        // 3 — Climbing → name the climb (PR 5's "Name this climb" alert) → log an attempt
        // (grade V4, default outcome Sent).
        addExerciseMenu("Climbing")
        nameThisClimb("Cave")
        sleep(1); snap("04-climbing-added")
        tapAddSetForLastExercise()
        typeIn(app.textFields["logset.grade"], "V4")
        snap("05-climb-sheet")
        app.buttons["logset.add"].tap()
        sleep(1); snap("06-climb-logged")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'V4'")).firstMatch
            .waitForExistence(timeout: 4), "the climb row should read its grade (V4 · …)")

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

        // 5 — Timed → log 0:45. The duration sheet defaults to the live timer (Timer mode); switch to
        // Manual to type an exact value (the live-timer path is covered by TimedSetTimerTests).
        addExerciseMenu("Timed exercise")
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
}
