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
        XCTAssertTrue(any("home.hero").waitForExistence(timeout: 6), "one earning session makes Home the training Home")
        XCTAssertTrue(app.buttons["buddy.hatch"].exists)
        snap("02-home-egg")
    }

    func testHistoryHatchesStraightToItsLevel() {
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Home"].tap()
        let hatch = app.buttons["buddy.hatch"]
        XCTAssertTrue(hatch.waitForExistence(timeout: 8), "an unhatched buddy offers Hatch")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Your 23 sessions already count")).firstMatch.exists,
                      "all 23 seeded sessions count")
        snap("03-home-meet")
        hatch.tap()
        let level = app.staticTexts["buddy.level"]
        XCTAssertTrue(level.waitForExistence(timeout: 10), "it grows through the stages, then shows its level")
        XCTAssertTrue(level.label.contains("Level"), level.label)
        snap("04-home-hatched")
    }

    /// P2 (prompt 149): Home → the buddy's screen → Form explained → pause (buddy sleeps, Form held) →
    /// end pause → how XP works → style (others locked).
    func testBuddyScreenFormPauseRulesAndStyle() {
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Home"].tap()
        let hatch = app.buttons["buddy.hatch"]
        XCTAssertTrue(hatch.waitForExistence(timeout: 8))
        hatch.tap()
        let open = app.buttons["buddy.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let level = app.staticTexts["buddyScreen.level"]
        XCTAssertTrue(level.waitForExistence(timeout: 6))
        XCTAssertTrue(level.label.contains("Level"), level.label)
        XCTAssertTrue(any("buddyScreen.streak").label.contains("🔥"), any("buddyScreen.streak").label)
        XCTAssertTrue(any("buddyScreen.recent").exists, "recent XP lists the seeded sessions")
        sleep(3); snap("05-buddy-screen")

        app.buttons["buddyScreen.form"].tap()
        XCTAssertTrue(app.navigationBars["Form"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Never your level or XP."].exists || app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Never your level'")).firstMatch.exists)
        snap("06-form-sheet")
        app.navigationBars["Form"].buttons["Done"].tap()

        app.buttons["buddyScreen.pause"].tap()
        XCTAssertTrue(app.navigationBars["Pause"].waitForExistence(timeout: 4))
        app.segmentedControls["pause.reason"].buttons["Injury"].tap()
        app.segmentedControls["pause.length"].buttons["2 weeks"].tap()
        snap("07-pause-sheet")
        app.buttons["pause.start"].tap()
        let mood = app.staticTexts["buddyScreen.mood"]
        XCTAssertTrue(mood.waitForExistence(timeout: 4))
        XCTAssertTrue(mood.label.hasPrefix("Resting"), mood.label)
        XCTAssertTrue(app.buttons["buddyScreen.endPause"].exists)
        XCTAssertTrue(any("buddyScreen.form").label.contains("Held while paused"), any("buddyScreen.form").label)
        sleep(1); snap("08-paused")
        app.buttons["buddyScreen.endPause"].tap()
        XCTAssertFalse(mood.label.hasPrefix("Resting"), mood.label)

        app.swipeUp()
        app.buttons["buddyScreen.rules"].tap()
        XCTAssertTrue(app.navigationBars["How XP works"].waitForExistence(timeout: 4))
        snap("09-rules")
        app.navigationBars["How XP works"].buttons["Done"].tap()
        app.buttons["buddyScreen.style"].tap()
        XCTAssertTrue(app.buttons["buddyStyle.athlete"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["buddyStyle.athlete"].label.contains("Coming soon"))
        snap("10-style")
    }

    /// Prompt 150: the training-first Home — hero, today, the week in XP, wins, coming up, other apps.
    func testTrainingHomeLeadsWithTheBuddy() {
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(any("trainingHome").waitForExistence(timeout: 8))
        let hatch = app.buttons["buddy.hatch"]
        XCTAssertTrue(hatch.waitForExistence(timeout: 6))
        hatch.tap()
        XCTAssertTrue(app.staticTexts["buddy.level"].waitForExistence(timeout: 10))
        XCTAssertTrue(any("home.today").exists, "today's training card")
        XCTAssertTrue(any("home.week").exists, "the week in XP")
        sleep(2); snap("11-home-top")
        app.swipeUp()
        XCTAssertTrue(any("home.wins").waitForExistence(timeout: 4), "recent wins from the seeded PRs / first send")
        XCTAssertTrue(any("home.comingUp").exists)
        sleep(1); snap("12-home-scrolled")

        // The hero opens the buddy's screen.
        app.swipeDown(); app.swipeDown()
        app.buttons["buddy.open"].tap()
        XCTAssertTrue(app.staticTexts["buddyScreen.level"].waitForExistence(timeout: 6))
    }
}
