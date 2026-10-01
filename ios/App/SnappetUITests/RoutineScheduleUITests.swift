import XCTest

/// Prompt 136: schedule a routine from its detail, see it summarized on the card, then find it on the
/// Routines list's Up next card and skip today.
@MainActor
final class RoutineScheduleUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
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

    /// Prompt 137: a scheduled routine tracked in Habits appears there as a linked habit whose Start
    /// strip opens the routine in the player.
    func testScheduledRoutineShowsAsLinkedHabitWithStart() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Routines"].tap()
        let row = app.buttons.matching(identifier: "routineRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        app.buttons["routine.schedule"].tap()
        XCTAssertTrue(app.buttons["schedule.save"].waitForExistence(timeout: 4))
        for wd in 1...7 {
            let day = app.buttons["schedule.day.\(wd)"]
            if day.value as? String != "Selected" { day.tap() }
        }
        app.buttons["schedule.save"].tap()
        XCTAssertTrue(app.buttons["routine.schedule"].label.contains("Tracked in Habits"),
                      app.buttons["routine.schedule"].label)

        // Over to Habits: back out of the detail (it hides the tab bar), then Apps → pop to the library.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 4))
        app.tabBars.buttons["Apps"].tap()   // re-tapping the selected tab pops to the library root
        XCTAssertTrue(app.buttons["moduleCard.habit"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.habit"].tap()
        let linked = app.descendants(matching: .any)["habit.linked"]
        XCTAssertTrue(linked.waitForExistence(timeout: 6), "the routine's habit shows its linked strip")
        snap("habits-linked")

        app.buttons["habit.startLinked"].tap()
        XCTAssertTrue(app.buttons["pauseWorkout"].waitForExistence(timeout: 8), "Start opens the routine in the player")
        snap("player-from-habits")
    }

    /// Prompt 138: Routines ＋ is a menu with Scan QR code / Import from Photos, and the share sheet can
    /// carry the schedule.
    func testScanEntryAndShareIncludesSchedule() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Routines"].tap()

        let add = app.buttons["routines.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4))
        add.tap()
        let scan = app.buttons["routines.menu.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 4), "＋ offers Scan QR Code")
        XCTAssertTrue(app.buttons["routines.menu.photos"].exists, "＋ offers Import from Photos")
        snap("routines-add-menu")
        scan.tap()
        XCTAssertTrue(app.buttons["routine.scanSheet.photos"].waitForExistence(timeout: 4),
                      "the scanner offers Choose from Photos")
        snap("scan-sheet")
        app.buttons["Cancel"].tap()

        // Schedule a routine, then its share sheet offers Include schedule.
        let row = app.buttons.matching(identifier: "routineRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        app.buttons["routine.schedule"].tap()
        XCTAssertTrue(app.buttons["schedule.save"].waitForExistence(timeout: 4))
        app.buttons["schedule.save"].tap()
        app.buttons["routine.share"].tap()
        let include = app.switches["routine.share.includeSchedule"]
        XCTAssertTrue(include.waitForExistence(timeout: 4), "a scheduled routine can share its schedule")
        XCTAssertEqual(include.value as? String, "1", "on by default")
        snap("share-with-schedule")
    }

    /// Prompt 144: several sessions a day — "Every 2 hours, 8 AM–8 PM" previews 7 times a day, saves into
    /// the summary, and Up next says which session of the day it is.
    func testEveryTwoHoursScheduleShowsSessionCount() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Routines"].tap()
        let row = app.buttons.matching(identifier: "routineRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        app.buttons["routine.schedule"].tap()
        XCTAssertTrue(app.buttons["schedule.save"].waitForExistence(timeout: 4))
        for wd in 1...7 {
            let day = app.buttons["schedule.day.\(wd)"]
            if day.value as? String != "Selected" { day.tap() }
        }
        let every = app.buttons["Every…"]
        for _ in 0..<3 where !every.isHittable { app.swipeUp() }
        every.tap()
        let preview = app.staticTexts["schedule.slotsPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 4))
        XCTAssertTrue(preview.label.hasPrefix("7 times a day"), preview.label)
        snap("schedule-every-2h")
        app.buttons["schedule.save"].tap()

        let card = app.buttons["routine.schedule"]
        XCTAssertTrue(card.waitForExistence(timeout: 4))
        XCTAssertTrue(card.label.contains("every 2 h"), card.label)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let when = app.staticTexts["upNext.when"]
        XCTAssertTrue(when.waitForExistence(timeout: 4))
        XCTAssertTrue(when.label.contains(" OF 7"), when.label)
        XCTAssertTrue(app.buttons["upNext.skipSlot"].exists, "skip a single session")
        snap("up-next-multi")
    }
}
