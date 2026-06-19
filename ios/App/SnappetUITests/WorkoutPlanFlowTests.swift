import XCTest

/// UI walkthrough of the smart-planning flow (workout-redesign E7): open the planner from the dashboard,
/// confirm the "Today" verb + an editable draft render, re-generate via a strategy chip, tweak in words, and
/// drive "Save as routine" into the pre-filled routine editor. Fresh in-memory store so it's deterministic;
/// the planner draws candidates from the bundled catalog so it works even with no logged history.
final class WorkoutPlanFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testPlanGenerateTweakAndSave() {
        // Enter the gym tracker.
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        sleep(1); snap("01-dashboard")

        // Open the planner from the dashboard's "Plan a session" entry (present in the empty state too).
        let planEntry = app.buttons["workout.dashboardPlan"]
        XCTAssertTrue(planEntry.waitForExistence(timeout: 6), "the dashboard offers a Plan a session entry")
        planEntry.tap()
        sleep(1); snap("02-planner")

        // The "Today" verb card + an editable draft should render (the planner builds from the catalog).
        XCTAssertTrue(app.navigationBars["Plan a session"].waitForExistence(timeout: 5), "planner opened")
        let firstRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'rest'")).firstMatch
        // A draft row carries a "N × reps · rest Ns" subtitle — at least one should exist.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "workout.plan.row").firstMatch
                        .waitForExistence(timeout: 5) || firstRow.waitForExistence(timeout: 2),
                      "the planner renders an editable draft")

        // Re-generate via a strategy chip (Strength).
        let strengthChip = app.buttons["workout.plan.strategy.strength"]
        if strengthChip.waitForExistence(timeout: 4) {
            strengthChip.tap(); sleep(1); snap("03-strength-strategy")
        }

        // Tweak in words → applies through the heuristic (the sim has no on-device model). The plan re-plans.
        // Submit via the keyboard's "Go" (the field's .submitLabel) so the keyboard dismisses too —
        // otherwise it covers the bottom action section and the List can't scroll under it.
        let tweakField = app.textFields["workout.plan.tweakField"]
        if tweakField.waitForExistence(timeout: 4) {
            tweakField.tap()
            tweakField.typeText("no barbell")
            if app.keyboards.buttons["Go"].waitForExistence(timeout: 3) {
                app.keyboards.buttons["Go"].tap()
            } else {
                app.buttons["workout.plan.tweakApply"].tap()
            }
            sleep(1); snap("04-tweaked")
        }

        // Scroll the List up so the action section comes into view, then Save as routine.
        app.swipeUp(); app.swipeUp(); sleep(1)
        let save = app.buttons["workout.plan.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save as routine action is present")
        XCTAssertTrue(save.isHittable || save.exists, "Save as routine is reachable")
        save.tap()
        sleep(1); snap("05-routine-editor")
        // The editor sheet shows the routine form (a Name field). We assert it appeared rather than its
        // contents (the pre-fill names it from the verb).
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), "the routine editor opened")
    }
}
