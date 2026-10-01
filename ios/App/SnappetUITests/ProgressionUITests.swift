import XCTest

/// Progression P1 (prompt 148): the finish screen shows what a session earned, and Home's buddy card
/// hatches straight to the level your history earned. ("Under 5 minutes earns nothing" is unit-tested:
/// it depends on wall-clock duration, which a UI test can't hold steady.)
final class ProgressionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func finishAQuickLift() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        app.buttons["moduleCard.workout-log"].tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        app.buttons["Lifting exercise"].tap()
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch.tap()
        app.buttons["freeform.quickWeight.plus"].tap()
        app.buttons["freeform.quickLog"].tap()
        let finish = app.buttons["freeform.finish"]
        if !finish.exists { app.swipeUp() }
        XCTAssertTrue(finish.waitForExistence(timeout: 6))
        finish.tap()
    }

    func testFinishScreenShowsXPThenHomeOffersTheEgg() {
        app.launchArguments += ["-uiTestFreshStore", "-uiTestXPAnyLength"]
        app.launch()
        finishAQuickLift()

        let total = any("xp.total")
        XCTAssertTrue(total.waitForExistence(timeout: 8), "the finish screen shows the XP earned")
        XCTAssertTrue(total.label.hasPrefix("+"), total.label)
        XCTAssertTrue(any("xp.items").label.contains("Session finished"), any("xp.items").label)
        XCTAssertTrue(any("xp.level").label.contains("Level"), any("xp.level").label)
        sleep(1); snap("01-finish-xp")

        app.buttons["freeform.done"].tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(any("buddy.homeCard").waitForExistence(timeout: 6), "one earning session puts the buddy on Home")
        XCTAssertTrue(app.buttons["buddy.hatch"].exists)
        snap("02-home-egg")
    }

    func testHistoryHatchesStraightToItsLevel() {
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Home"].tap()
        let hatch = app.buttons["buddy.hatch"]
        XCTAssertTrue(hatch.waitForExistence(timeout: 8), "an unhatched buddy offers Hatch")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your 23 so far count")).firstMatch.exists,
                      "all 23 seeded sessions count")
        snap("03-home-meet")
        hatch.tap()
        let level = app.staticTexts["buddy.level"]
        XCTAssertTrue(level.waitForExistence(timeout: 10), "it grows through the stages, then shows its level")
        XCTAssertTrue(level.label.contains("Level"), level.label)
        snap("04-home-hatched")
    }
}
