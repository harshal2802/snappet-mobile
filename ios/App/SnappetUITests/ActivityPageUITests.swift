import XCTest

/// The Activity page (Library redesign L2, prompt 184): Progress · Clips · About tabs, Log it now, Add to routine,
/// and the Explore "done" badge. Seeded by `-uiTestSeedActivityClips` (routine history + bench clips).
@MainActor
final class ActivityPageUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedActivityClips"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Library"].tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func openBench() {
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'library.yours.row' AND label CONTAINS 'Bench'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        XCTAssertTrue(any("activity.tabs").waitForExistence(timeout: 6), "the page's tabs")
    }

    func testTabsAboutAndAddToRoutine() {
        openBench()
        let tabs = app.segmentedControls.matching(identifier: "activity.tabs").firstMatch
        XCTAssertTrue(tabs.buttons["Progress"].isSelected)
        XCTAssertTrue(tabs.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Clips'")).firstMatch.exists)
        snap("01-progress")

        tabs.buttons["Clips · 4"].tap()
        XCTAssertTrue(any("activity.clips.summary").waitForExistence(timeout: 4), "the clips tab")
        snap("02-clips")

        tabs.buttons["About"].tap()
        XCTAssertTrue(app.staticTexts["Instructions"].waitForExistence(timeout: 4) || app.staticTexts["INSTRUCTIONS"].exists,
                      "a catalog move's how-to")
        snap("03-about")

        any("activity.addToRoutine").tap()
        let push = app.buttons["Push Day"]
        XCTAssertTrue(push.waitForExistence(timeout: 3))
        push.tap()
        XCTAssertTrue(app.staticTexts["Added to Push Day"].waitForExistence(timeout: 3), "the confirmation")
        snap("04-added")
    }

    func testLogItNowStartsAQuickSessionWithIt() {
        // Through Explore — the catalog path doesn't depend on seeded history.
        app.segmentedControls.matching(identifier: "library.mode").firstMatch.buttons["Explore"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap(); search.typeText("Barbell Bench Press - Medium")
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'exerciseRow' AND label CONTAINS 'Medium Grip'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.tap()
        XCTAssertTrue(any("activity.logNow").waitForExistence(timeout: 6), "the Activity page")
        any("activity.logNow").tap()
        // The player opens on the bench page, prefilled from last time.
        let name = any("freeform.entityName")
        XCTAssertTrue(name.waitForExistence(timeout: 8), "the session player")
        XCTAssertTrue(name.label.contains("Bench"), name.label)
        snap("05-logging")

        // Clean up: finish + discard so the live workout doesn't leak into the next launch (an un-ended one left the
        // next run's seeded history empty — the WorkoutPauseBackgroundTests rule).
        app.buttons["freeform.finish"].tap()
        let discard = app.buttons["freeform.discard"]
        if discard.waitForExistence(timeout: 4) {
            discard.tap()
            let confirm = app.buttons["Discard (don't save)"]
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        }
    }

    func testExploreMarksMovesYouveDone() {
        app.segmentedControls.matching(identifier: "library.mode").firstMatch.buttons["Explore"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap(); search.typeText("Barbell Bench Press")
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'exerciseRow' AND label CONTAINS 'Done'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "a done badge on the bench")
        snap("06-explore-done")
    }
}
