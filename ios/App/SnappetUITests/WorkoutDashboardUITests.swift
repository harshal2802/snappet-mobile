import XCTest

/// Prompt 217: the restyled Gym Tracker Dashboard — everything still there, and "See all" beside Recent
/// sessions opens History (its action used to be empty).
final class WorkoutDashboardUITests: XCTestCase {
    private func snap(_ app: XCUIApplication, _ n: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a)
    }

    func testDashboardSectionsAndSeeAllOpensHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        XCTAssertTrue(app.buttons["workout.dashboardStart"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["workout.dashboardPlan"].exists)
        XCTAssertTrue(app.buttons["workout.recentSession"].firstMatch.exists)
        sleep(1); snap(app, "dash-top")
        app.swipeUp(); sleep(1); snap(app, "dash-mid")
        app.swipeUp(); sleep(1); snap(app, "dash-bottom")
        app.swipeDown(); app.swipeDown()

        let seeAll = app.buttons["workout.recentSeeAll"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 4))
        seeAll.tap()
        XCTAssertTrue(app.buttons["history.filtersButton"].waitForExistence(timeout: 6), "See all opens History")
    }
}
