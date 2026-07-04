import XCTest

/// UI coverage for the **Quick Session full-screen pager** (prompt 109): the plan editor
/// (`freeform.planEdit` → `PlanEditorSheet` → segments), the plan-complete nudge
/// (`freeform.nudgeNext` / `freeform.nudgeExtra`), and the exercise rail + overview page
/// (jump to `freeform.rail.0`, tap an `freeform.overviewRow` back to the exercise). Drives the
/// real Quick Start → Lifting path with a fresh store, like the rest of the freeform suite.
final class QuickSessionPagerUITests: XCTestCase {
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

    private func addLiftingExercise() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Lifting exercise"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "the Lifting menu item should appear")
        opt.tap()
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker should list exercises")
        row.tap()
        let addLift = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addLift.waitForExistence(timeout: 4), "the picker's Add commit button should appear")
        addLift.tap()
    }

    func testPlanFlowNudgeAndOverviewJump() {
        openFreeformPlayer()
        addLiftingExercise()

        // The pager auto-advances to the new exercise's page: the strength hero is visible.
        let log = app.buttons["freeform.quickLog"]
        XCTAssertTrue(log.waitForExistence(timeout: 6), "the strength hero should be on the new page")
        snap("01-strength-page")

        // 1 — Set a plan of 2 via the plan editor (fresh store → no last-time default → opens at 3).
        let planEdit = app.buttons["freeform.planEdit"]
        XCTAssertTrue(planEdit.waitForExistence(timeout: 4), "the plan row should be tappable")
        planEdit.tap()
        let minus = app.buttons["freeform.planMinus"]
        XCTAssertTrue(minus.waitForExistence(timeout: 5), "the plan editor should open")
        minus.tap()
        XCTAssertEqual(app.staticTexts["freeform.planValue"].label, "2",
                       "3 (the no-history default) − 1 should read 2")
        snap("02-plan-editor")
        app.buttons["freeform.planSave"].tap()

        // 2 — Log the 2 planned sets; the hero collapses into the plan-complete nudge.
        XCTAssertTrue(log.waitForExistence(timeout: 4)); log.tap()
        XCTAssertTrue(log.waitForExistence(timeout: 4), "hero re-seeds after set 1"); log.tap()
        let nudge = app.buttons["freeform.nudgeNext"]
        XCTAssertTrue(nudge.waitForExistence(timeout: 6),
                      "meeting the plan should collapse the hero into the done nudge")
        XCTAssertEqual(nudge.label, "Finish workout",
                       "with no other unfinished exercise the nudge offers Finish")
        snap("03-plan-complete-nudge")

        // 3 — "+1 extra set" re-opens the plan (2 → 3) and brings the hero back.
        app.buttons["freeform.nudgeExtra"].tap()
        XCTAssertTrue(log.waitForExistence(timeout: 5), "an extra set should re-open the hero")

        // 4 — Jump to the overview via the rail: title field + the exercise row with its segments.
        let overviewChip = app.buttons["freeform.rail.0"]
        XCTAssertTrue(overviewChip.waitForExistence(timeout: 4), "the rail should offer the overview chip")
        overviewChip.tap()
        XCTAssertTrue(app.textFields["freeform.sessionTitle"].waitForExistence(timeout: 5),
                      "the overview page should host the editable session title")
        let row = app.buttons["freeform.overviewRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 4), "the overview should list the exercise")
        snap("04-overview")

        // 5 — Tapping the row jumps back to the exercise page.
        row.tap()
        XCTAssertTrue(log.waitForExistence(timeout: 5),
                      "tapping an overview row should jump the pager to that exercise's page")
        snap("05-back-on-page")
    }
}
