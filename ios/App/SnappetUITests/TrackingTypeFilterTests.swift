import XCTest

/// UI coverage for the **tracking-type search facet** in the History section (workout-with-timer
/// PR 6): a row of toggle chips (Reps & weight / Time / Climb — the `SetKind`s) that keeps sessions
/// tracking any selected kind, alongside the existing routine-name + text search (issue #73).
///
/// Drives the real flow: Quick Start a freeform session → log ONE Timed set (Manual mode, an exact
/// value) → Finish → open History → toggle the "Time" chip (`history.kindChip.duration`) and assert
/// the just-finished session row is still shown, then toggle the "Reps & weight" chip
/// (`history.kindChip.repsWeight`) — a kind this session does NOT track — and assert it's hidden.
/// The store is launched fresh (`-uiTestFreshStore`), so History holds exactly the one timed session
/// and the chip's narrow/widen is unambiguous.
///
/// UI-test lessons obeyed (PR 2–5): leaf ids only (each chip carries its own id; no id on a composite
/// row); query rows type-agnostically (`descendants(matching: .any).matching(identifier:)`, not
/// `app.cells`, since iOS 26 collapses composites); assert distinctive presence/absence of the row.
@MainActor final class TrackingTypeFilterTests: XCTestCase {
    var app: XCUIApplication!

    // Async setUp so the @MainActor class isolates it too (a sync `setUp()` override stays nonisolated and
    // warns on every main-actor `app` access).
    override func setUp() async throws {
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

    /// Add a Timed exercise via the add-exercise menu. Since the Quick Session redesign (#175) the
    /// "Timed exercise" item opens the pick-or-create sheet (`PickTimedExerciseSheet`) rather than dropping a
    /// bare card, so pick a seeded suggestion (Free hold — an open count-up) and wait for the named card. Same
    /// navigation `TimedSetTimerTests` uses.
    private func addTimedExerciseViaPicker() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Timed exercise"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "the 'Timed exercise' menu item should appear")
        opt.tap()
        XCTAssertTrue(app.buttons["timed.createNew"].waitForExistence(timeout: 6),
                      "the timed pick-or-create sheet should open with 'Create new' pinned")
        let suggestion = app.buttons["timed.suggested.seed.freehold"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "a seeded timed suggestion should be offered")
        suggestion.tap()
        XCTAssertTrue(app.staticTexts["freeform.timedName"].waitForExistence(timeout: 5)
            || app.otherElements["freeform.timedName"].waitForExistence(timeout: 2),
            "the picked timed exercise should land as a named card")
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

    func testTrackingTypeChipNarrowsHistoryToTheSessionsKind() {
        // 1 — Quick Start → freeform player → add a Timed exercise and log one duration set (Manual,
        // an exact 0:45 — the live-timer path is TimedSetTimerTests' job; here we just need a Timed set).
        openFreeformPlayer()
        snap("01-freeform")
        addTimedExerciseViaPicker()
        sleep(1); snap("02-timed-added")
        tapAddSetForLastExercise()
        let manual = app.segmentedControls.buttons["Manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5), "the duration sheet should offer a Manual mode")
        manual.tap()
        typeIn(app.textFields["Min"], "0")
        typeIn(app.textFields["Sec"], "45")
        snap("03-timed-sheet")
        app.buttons["logset.add"].tap()
        sleep(1); snap("04-timed-logged")

        // 2 — Finish the session. Finish opens the completion summary (#158 §D); its Done button saves &
        // exits to the dashboard.
        let finish = app.buttons["freeform.finish"]
        if !finish.exists { app.swipeUp() }
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "Finish workout should be available")
        finish.tap()
        let done = app.buttons["freeform.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the completion summary should appear")
        done.tap()
        sleep(2); snap("05-after-finish")

        // 3 — Open History. The just-finished freeform session ("Quick session", Timed-only) is the
        // only row in the fresh store, so the facet's narrow/widen below is unambiguous.
        let historyTab = app.segmentedControls.buttons["History"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 6), "the History segment should exist")
        historyTab.tap()
        sleep(1); snap("06-history")
        XCTAssertTrue(rowExists(timeout: 6), "the finished session should appear in History before filtering")

        // 4 — Toggle the "Time" chip (matches the Timed session) → the row stays shown.
        let timeChip = app.descendants(matching: .any).matching(identifier: "history.kindChip.duration").firstMatch
        XCTAssertTrue(timeChip.waitForExistence(timeout: 6), "the Time tracking-type chip should render")
        timeChip.tap()
        sleep(1); snap("07-time-on")
        XCTAssertTrue(rowExists(timeout: 4),
                      "filtering by Time should keep the session that tracked a Timed set")

        // 5 — Also turn on "Reps & weight" (a kind this session does NOT track). The selection is a
        // union, so the timed session still matches via Time and stays shown.
        let repsChip = app.descendants(matching: .any).matching(identifier: "history.kindChip.repsWeight").firstMatch
        XCTAssertTrue(repsChip.waitForExistence(timeout: 4), "the Reps & weight chip should render")
        repsChip.tap()
        sleep(1); snap("08-reps-also-on")
        XCTAssertTrue(rowExists(timeout: 4),
                      "Time + Reps & weight is a union — the timed session still matches via Time")

        // 6 — Turn "Time" back off, leaving only "Reps & weight" selected. The Timed-only session no
        // longer matches any selected kind → it's hidden (the distinctive narrowing assertion).
        timeChip.tap()
        sleep(1); snap("09-only-reps")
        XCTAssertFalse(rowExists(timeout: 2),
                       "with only Reps & weight selected, the Timed-only session must be filtered out")
    }

    /// Any History session row, queried type-agnostically (the row is a value-based `NavigationLink`
    /// labeled `historyRow`; iOS 26 may not surface it as a `.cell`).
    private func rowExists(timeout: TimeInterval) -> Bool {
        let row = app.descendants(matching: .any).matching(identifier: "historyRow").firstMatch
        return row.waitForExistence(timeout: timeout)
    }
}
