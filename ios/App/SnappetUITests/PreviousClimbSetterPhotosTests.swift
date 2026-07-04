import XCTest

/// UI coverage for the **"Add a climb" follow-up** (prompt 81): the optional **Setter** field, the optional
/// **Photos** attach control, and the **"Log a previous climb"** re-log picker that surfaces the user's
/// distinct past climbs and prefills the form on selection.
///
/// Drives the real path — Quick Start → tap Climbing → confirm the Setter field + Photos attach affordance
/// are present in the Add-a-climb sheet → log a first climb (V3 "Cave Project", setter "Alex H.") → reopen
/// the sheet → expand "Log a previous climb" → pick the first row → assert the form prefilled (grade V3,
/// name + setter) → "Add climb" → assert a SECOND climb card now exists (a re-log is a brand-new climb, not
/// a mutation of history).
///
/// Fresh-store launch like the rest of SnappetUITests so the run never inherits a leftover active session.
final class PreviousClimbSetterPhotosTests: XCTestCase {
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

    /// Open the add-exercise menu and tap "Climbing" (which presents the "Add a climb" sheet).
    private func tapAddClimbingMenuItem() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Climbing"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "menu item Climbing should appear")
        opt.tap()
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    /// Tap any element matching `id` (robust to which trait SwiftUI exposes a control as).
    private func tapAny(_ id: String, timeout: TimeInterval = 5) {
        let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "\(id) should exist")
        el.tap()
    }

    /// Swipe the sheet up until an element matching `id` is in the tree (a SwiftUI `Form` renders
    /// off-screen sections lazily, so lower sections aren't queryable until scrolled near).
    @discardableResult
    private func revealElement(_ id: String, tries: Int = 5) -> XCUIElement {
        let el = app.descendants(matching: .any).matching(identifier: id).firstMatch
        var n = 0
        while !el.exists && n < tries { app.swipeUp(); n += 1 }
        return el
    }

    func testSetterPhotosAndReLogAPreviousClimb() {
        openFreeformPlayer()

        // 1) The Add-a-climb sheet now offers a Setter field and a Photos attach affordance (ADD mode).
        tapAddClimbingMenuItem()
        XCTAssertTrue(app.segmentedControls["addClimb.type"].waitForExistence(timeout: 6),
                      "the Add-a-climb sheet should present a TYPE picker")
        XCTAssertTrue(app.textFields["addClimb.setter"].waitForExistence(timeout: 4),
                      "the sheet should offer an optional Setter field")

        // Enter the climb identity (top/mid of the form): grade V3, name, setter.
        app.buttons["addClimb.rung.V3"].tap()
        XCTAssertEqual(app.staticTexts["addClimb.gradeValue"].label, "V3")
        typeIn(app.textFields["addClimb.name"], "Cave Project\n")   // \n dismisses the keyboard so the
        typeIn(app.textFields["addClimb.setter"], "Alex H.\n")      // next (lower) field re-renders in the Form
        snap("01-add-sheet-setter")

        // The Photos attach affordance lives lower in the form — scroll to reveal it (ADD mode).
        XCTAssertTrue(revealElement("addClimb.attachPhoto").exists,
                      "the sheet should offer a Photos attach affordance (ADD mode)")
        snap("02-photos-affordance")

        // "Add & log first attempt" (now in view after scrolling) → opens the inline outcome strip.
        let addAndLog = app.buttons["addClimb.addAndLog"]
        XCTAssertTrue(addAndLog.waitForExistence(timeout: 4), "the prominent CTA should be present")
        addAndLog.tap()
        let sent = app.buttons["freeform.outcome.sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 6), "the new card should open its inline outcome strip")
        sent.tap()
        sleep(1); snap("02-first-climb-logged")

        // 2) Reopen the sheet — the just-logged climb is now a "previous climb" (derived from this session).
        tapAddClimbingMenuItem()
        XCTAssertTrue(app.segmentedControls["addClimb.type"].waitForExistence(timeout: 6),
                      "the Add-a-climb sheet should reopen")
        // Expand "Log a previous climb" → its search + a row should appear.
        tapAny("addClimb.previousDisclosure")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "addClimb.previousSearch")
            .firstMatch.waitForExistence(timeout: 4), "expanding should reveal the search field")
        let row = app.descendants(matching: .any).matching(identifier: "addClimb.previousRow.0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "the previous climb should appear as a row")
        snap("03-previous-list")

        // 3) Selecting it prefills the whole form (grade, name, setter) for a fresh re-log.
        row.tap()
        XCTAssertEqual(app.staticTexts["addClimb.gradeValue"].label, "V3",
                       "selecting a previous climb prefills its grade")
        XCTAssertEqual(app.textFields["addClimb.name"].value as? String, "Cave Project",
                       "selecting a previous climb prefills its name")
        XCTAssertEqual(app.textFields["addClimb.setter"].value as? String, "Alex H.",
                       "selecting a previous climb prefills its setter (the setter round-trips)")
        snap("04-prefilled")

        // Commit as a brand-new climb (not an edit) → a SECOND "Cave Project" card now exists.
        // "Add climb" sits at the bottom of the form — scroll to reveal it.
        let addBtn = revealElement("addClimb.add")
        XCTAssertTrue(addBtn.exists, "the 'Add climb' CTA should be present")
        addBtn.tap()
        // The pager auto-advances to the new climb's page; its title reads the re-logged name…
        let name = app.staticTexts["freeform.climbName"]
        XCTAssertTrue(name.waitForExistence(timeout: 6),
                      "re-logging a previous climb should land on the new climb's page")
        XCTAssertEqual(name.label, "Cave Project", "the re-logged climb keeps the previous climb's name")
        // …and the rail now has 2 exercise chips (overview · climb · climb · add = 4 chips), proving a
        // second distinct climb exists rather than the first being mutated (pager, prompt 109).
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'freeform.rail.'"))
        XCTAssertGreaterThanOrEqual(chips.count, 4, "two climb chips should now be on the rail")
        snap("05-relogged-second-card")
    }
}
