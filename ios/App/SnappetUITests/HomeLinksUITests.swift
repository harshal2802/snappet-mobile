import XCTest

/// Prompt 212: everything on Home opens where it came from (user, 2026-10-29: "make sure everything you show in home
/// has a deep link to get to its source"). Walks the links on the seeded routine history.
final class HomeLinksUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Home"].tap()
        let hatch = app.buttons["buddy.hatch"]
        XCTAssertTrue(hatch.waitForExistence(timeout: 8))
        hatch.tap()
        XCTAssertTrue(app.buttons["buddy.open"].waitForExistence(timeout: 10))
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func backHome() {
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["buddy.open"].waitForExistence(timeout: 6))
    }

    func testAvatarOpensSettings() {
        sleep(1); snap("home-top")
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.appearance"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["settings.heartRate"].exists)
        XCTAssertTrue(app.buttons["settings.backup"].exists)
        snap("settings")
        app.buttons["settings.appearance"].tap()
        XCTAssertTrue(any("settings.appearance.preview").waitForExistence(timeout: 4))
    }

    func testWeekOpensHistoryOnThisWeek() {
        app.buttons["home.week"].tap()
        let token = app.buttons["history.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 6), "History opens filtered to the week")
        XCTAssertTrue(token.label.contains("This week"), token.label)
        snap("history-this-week")
        token.tap()
        XCTAssertFalse(app.buttons["history.token"].waitForExistence(timeout: 1), "the chip clears the range")
    }

    func testDayBarOpensThatDay() {
        app.buttons.matching(identifier: "home.week.day").element(boundBy: 0).tap()
        let token = app.buttons["history.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 6))
        XCTAssertFalse(token.label.contains("week"), token.label)
    }

    func testStreakOpensYourBuddy() {
        app.buttons["home.streak"].tap()
        XCTAssertTrue(app.staticTexts["buddyScreen.level"].waitForExistence(timeout: 6))
    }

    func testWinOpensItsSession() {
        let win = app.buttons["home.win"].firstMatch
        for _ in 0..<3 where !win.isHittable { app.swipeUp() }
        sleep(1); snap("home-scrolled")
        win.tap()
        let detail = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.'")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 6), "the win opens its session's detail")
        snap("win-session")
    }

    func testTodayOpensTheRoutine() throws {
        let open = app.buttons["home.today.open"]
        guard open.waitForExistence(timeout: 3) else {
            throw XCTSkip("no session planned today in the seed (depends on the weekday)")
        }
        open.tap()
        XCTAssertTrue(any("routine.share").waitForExistence(timeout: 6) || any("routine.schedule").exists,
                      "the today card opens the routine's page")
    }

    func testMilestoneOpensTheRoutine() {
        let row = app.buttons["home.comingUp.milestone"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        sleep(1); snap("home-lower")
        row.tap()
        // The seed's nearest milestone is a quick-session series (no routine) → its latest session.
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'routine.share' OR identifier BEGINSWITH 'session.'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 6), "the milestone opens its routine or latest session")
    }
}
