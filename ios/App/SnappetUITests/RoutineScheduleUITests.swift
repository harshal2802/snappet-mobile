import XCTest

/// Prompt 136: schedule a routine from its detail, see it summarized on the card, then find it on the
/// Routines list's Up next card and skip today.
final class RoutineScheduleUITests: XCTestCase {
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

    func testScheduleEveryDayShowsUpNextAndSkips() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Routines"].tap()

        // No schedule yet → no Up next card.
        let row = app.buttons.matching(identifier: "routineRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        XCTAssertFalse(app.otherElements["upNext.card"].exists)
        row.tap()

        let card = app.buttons["routine.schedule"]
        XCTAssertTrue(card.waitForExistence(timeout: 4))
        XCTAssertTrue(card.label.contains("Not scheduled"), card.label)
        card.tap()

        // Every weekday on, so today is always a planned day regardless of when the test runs.
        XCTAssertTrue(app.buttons["schedule.save"].waitForExistence(timeout: 4))
        for wd in 1...7 {
            let day = app.buttons["schedule.day.\(wd)"]
            if day.value as? String != "Selected" { day.tap() }
        }
        snap("schedule-editor")
        app.buttons["schedule.save"].tap()

        XCTAssertTrue(card.waitForExistence(timeout: 4))
        XCTAssertTrue(card.label.contains("Every day"), card.label)
        snap("routine-detail-scheduled")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let upNext = app.otherElements["upNext.card"]
        XCTAssertTrue(upNext.waitForExistence(timeout: 4), "a scheduled routine shows the Up next card")
        XCTAssertTrue(app.staticTexts["upNext.when"].label.contains("TODAY"), app.staticTexts["upNext.when"].label)
        snap("routines-up-next")

        // Skip today → Up next moves to tomorrow.
        app.buttons["upNext.skip"].tap()
        let when = app.staticTexts["upNext.when"]
        let deadline = Date().addingTimeInterval(4)
        while !when.label.contains("TOMORROW"), Date() < deadline { usleep(200_000) }
        XCTAssertTrue(when.label.contains("TOMORROW"), when.label)
        snap("routines-up-next-skipped")
    }
}
