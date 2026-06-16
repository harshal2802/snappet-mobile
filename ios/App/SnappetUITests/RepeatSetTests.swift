import XCTest

/// UI coverage for the **one-tap repeat-set loop** (workout-with-timer PR 3): in the freeform player,
/// each exercise with ≥1 logged set shows a "Repeat set" control (`freeform.repeatSet`) that appends a
/// COPY of the most recent set — same fields, fresh `completedAt` — WITHOUT opening `LogSetSheet`.
/// Drives the real path — Quick Start → add a Lifting exercise → log one set (reps+weight via the sheet)
/// → tap Repeat set once → assert a SECOND `freeform.setRow` with the same values appears (count 1→2).
///
/// Same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover active
/// session. Extract shots with `xcrun xcresulttool export attachments`.
final class RepeatSetTests: XCTestCase {
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

    /// Add a Lifting exercise via the picker (first listed exercise — every row's subtitle ends in a
    /// level word, which the selection circle and the player behind the sheet don't have). Mirrors
    /// `FreeformFlowWalkthroughTests`, deliberately NOT using `.searchable` (iOS 26 hides the nav-bar
    /// commit button while search is active).
    private func addLiftingExercise() {
        addExerciseMenu("Lifting exercise")
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker should list exercises")
        row.tap()
        let addLift = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addLift.waitForExistence(timeout: 4), "the picker's Add commit button should appear")
        addLift.tap()
    }

    /// Count freeform set rows TYPE-AGNOSTICALLY: these rows are content HStacks (a static-text /
    /// container element), NOT List cells — `app.cells[...]` would miss them (PR 2 lesson).
    private func setRowCount() -> Int {
        app.descendants(matching: .any).matching(identifier: "freeform.setRow").count
    }

    func testRepeatSetDuplicatesTheLastSetWithOneTap() {
        openFreeformPlayer()
        snap("01-freeform")

        // Add a Lifting exercise and log one set: 8 reps × 60 (kg) via the sheet.
        addLiftingExercise()
        sleep(1); snap("02-lifting-added")
        tapAddSetForLastExercise()
        typeIn(app.textFields["logset.reps"], "8")
        typeIn(app.textFields["logset.weight"], "60")
        snap("03-lift-sheet")
        app.buttons["logset.add"].tap()
        sleep(1); snap("04-one-set")

        // Exactly one set row so far, reading its reps×weight via SetMeasure.summary ("8 × 60 kg").
        let firstRow = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 6), "the logged set row should appear")
        XCTAssertEqual(setRowCount(), 1, "exactly one set logged before Repeat")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'kg'")).firstMatch
            .waitForExistence(timeout: 4), "the lifting row should read its weight (8 × 60 kg)")

        // The one-tap Repeat control is present (the exercise has a set). Tapping it once duplicates the
        // last set — NO sheet — so the row count goes 1 → 2 with the same value.
        let repeatBtn = app.buttons["freeform.repeatSet"]
        XCTAssertTrue(repeatBtn.waitForExistence(timeout: 4),
                      "an exercise with a logged set should offer a one-tap Repeat set control")
        repeatBtn.tap()
        snap("05-repeated")

        // Two identical set rows now. Wait on the count rising to 2 (the append + persist is async).
        let twoRows = expectation(for: NSPredicate(format: "count == 2"),
                                  evaluatedWith: app.descendants(matching: .any)
                                    .matching(identifier: "freeform.setRow"))
        XCTAssertEqual(XCTWaiter().wait(for: [twoRows], timeout: 6), .completed,
                       "Repeat set should append a second set row (count 1 → 2)")
        sleep(1); snap("06-two-sets")

        // No LogSetSheet was opened by Repeat: its Add commit button must not be present.
        XCTAssertFalse(app.buttons["logset.add"].exists,
                       "Repeat set must NOT open the log sheet")

        // Both rows read the same value — the repeat logged an identical set, not a blank one.
        let kgRows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '60 kg'"))
        XCTAssertEqual(kgRows.count, 2, "both set rows should read the same '8 × 60 kg'")
    }
}
