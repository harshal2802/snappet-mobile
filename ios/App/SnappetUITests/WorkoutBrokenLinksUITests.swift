import XCTest

/// Prompt 265: broken links and stale states from the workout state-machine review, on the simulator.
/// F12: a planned session's Start while a workout runs asks (Go to running workout / Cancel) and the plan stays.
/// F13: a reminder's Start now for a deleted / empty routine says so and lands on the workout home
/// (`-uiTestReminderStart missing|empty`, as a tapped notification action). F15: the Live Activity's link
/// (`snappet://workout`) opens the running workout, does nothing over an open player, and never tears down an open
/// racket recording screen. Screenshots with `RACKET_SHOTS=<dir>` (via `TEST_RUNNER_RACKET_SHOTS`).
@MainActor
final class WorkoutBrokenLinksUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["RACKET_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        let bottom = app.windows.firstMatch.frame.maxY - 90
        while (!el.isHittable || el.frame.maxY > bottom) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openGymTracker() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 6))
    }

    /// Quick Start, then minimize: a workout is running with the player closed.
    private func startAndMinimize() {
        app.buttons["workout.quickStart"].tap()
        let minimize = app.buttons["minimizeWorkout"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 8), "the live player")
        minimize.tap()
        XCTAssertFalse(minimize.waitForExistence(timeout: 2), "minimized")
    }

    // MARK: F12

    func testAPlannedStartWhileAWorkoutRunsAsksAndKeepsThePlan() {
        app.launchArguments += ["-uiTestFreshStore"]
        app.launchOnTestStore()
        openGymTracker()
        startAndMinimize()

        tapWhenHittable(app.buttons["workout.dashboardPlan"])
        XCTAssertTrue(app.navigationBars["Plan a session"].waitForExistence(timeout: 6), "the planner")
        let start = app.buttons["workout.plan.start"]
        tapWhenHittable(start)
        let alert = app.alerts["A workout is already running"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6), "Start asks instead of silently resuming")
        XCTAssertTrue(text(containing: "“Quick session” is still going. Go to it, or cancel and start this plan after "
                           + "you finish it. Your plan stays here.").exists)
        shot("01-planned-start-asks")

        let cancel = alert.buttons.matching(identifier: "workout.plan.startCancel").firstMatch
        XCTAssertEqual(cancel.label, "Cancel")
        cancel.tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Plan a session"].exists, "Cancel keeps you on the plan")
        XCTAssertTrue(start.exists, "the plan is still there")
        XCTAssertFalse(app.buttons["minimizeWorkout"].exists, "nothing started or resumed")

        tapWhenHittable(start)
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        let goTo = alert.buttons.matching(identifier: "workout.plan.goToRunning").firstMatch
        XCTAssertEqual(goTo.label, "Go to running workout")
        goTo.tap()
        let minimize = app.buttons["minimizeWorkout"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 8), "the running workout's player")
        XCTAssertTrue(text(containing: "Quick session").exists, "the running workout, not the plan")
        shot("02-go-to-running-workout")

        minimize.tap()
        XCTAssertTrue(app.navigationBars["Plan a session"].waitForExistence(timeout: 6), "the plan is still there")
        XCTAssertTrue(start.exists)
        shot("03-plan-kept")
    }

    // MARK: F13

    func testAReminderStartForADeletedRoutineSaysSoAndLandsOnTheWorkoutHome() {
        app.launchArguments += ["-uiTestFreshStore", "-uiTestReminderStart", "missing"]
        app.launchOnTestStore()
        let alert = app.alerts["Routine not found"]
        XCTAssertTrue(alert.waitForExistence(timeout: 12), "the reminder's Start now says why nothing started")
        XCTAssertTrue(text(containing: "This routine no longer exists. It may have been deleted, so there’s nothing to start.").exists)
        shot("04-reminder-routine-gone")
        alert.buttons.matching(NSPredicate(format: "label == %@", "OK")).firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 6), "on the workout home")
        XCTAssertFalse(app.buttons["minimizeWorkout"].exists, "nothing started")
        shot("05-reminder-lands-home")
    }

    func testAReminderStartForAnEmptyRoutineSaysSo() {
        app.launchArguments += ["-uiTestFreshStore", "-uiTestReminderStart", "empty"]
        app.launchOnTestStore()
        let alert = app.alerts["Nothing to start"]
        XCTAssertTrue(alert.waitForExistence(timeout: 12))
        XCTAssertTrue(text(containing: "“Leg day” has no exercises yet. Add some in Routines, then start it.").exists)
        shot("06-reminder-routine-empty")
        alert.buttons.matching(NSPredicate(format: "label == %@", "OK")).firstMatch.tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 6), "on the workout home")
        XCTAssertFalse(app.buttons["minimizeWorkout"].exists, "nothing started")
    }

    // MARK: F15

    /// `XCUIDevice.shared.system.open` delivers the link to the RUNNING app, as a Live Activity tap does.
    func testTheLiveActivityLinkOpensTheRunningWorkoutFromElsewhere() throws {
        try TestStoreGuard.skipLinkTestsOnDevice()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launchOnTestStore()
        openGymTracker()
        startAndMinimize()
        app.tabBars.buttons["Home"].tap()
        XCTAssertFalse(app.buttons["workout.quickStart"].waitForExistence(timeout: 2), "away from the Gym Tracker")

        XCUIDevice.shared.system.open(URL(string: "snappet://workout")!)
        let minimize = app.buttons["minimizeWorkout"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 10), "the running workout's player opened")
        shot("07-live-activity-opens-player")

        // Again with the player already up: nothing moves.
        XCUIDevice.shared.system.open(URL(string: "snappet://workout")!)
        XCTAssertTrue(minimize.waitForExistence(timeout: 6))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(minimize.exists, "still on the player")
    }

    // MARK: Prompt 279 — a fresh start mid-workout

    /// iOS closed the app behind a running workout; opening it again lands on the workout, not on Home.
    func testAFreshStartWithAWorkoutRunningOpensTheWorkout() {
        app.launchArguments += ["-uiTestSeedRunningWorkout"]
        app.launchOnTestStore()
        XCTAssertTrue(app.buttons["minimizeWorkout"].waitForExistence(timeout: 12), "the running workout's player opened")
        shot("08-fresh-start-opens-running-workout")
    }

    /// A workout left unfinished for hours is offered on Home, not jumped to.
    func testAFreshStartWithAForgottenWorkoutStaysOnHome() {
        app.launchArguments += ["-uiTestSeedRunningWorkoutOld"]
        app.launchOnTestStore()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["minimizeWorkout"].waitForExistence(timeout: 4), "no jump into the player")
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
    }

    func testTheLiveActivityLinkNeverTearsDownAnOpenRecording() throws {
        try TestStoreGuard.skipLinkTestsOnDevice()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera"]
        app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
        app.launchOnTestStore()
        openGymTracker()
        app.buttons["workout.quickStart"].tap()
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        XCTAssertTrue(app.buttons["racket.sport.tableTennis"].waitForExistence(timeout: 5))
        app.buttons["racket.sport.tableTennis"].tap()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
        let opponent = app.textFields["racket.opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Alex\n")
        tapWhenHittable(app.buttons["racket.recording.everything"])
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])
        let shutter = app.buttons["racket.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 8))
        shutter.tap()
        XCTAssertTrue(app.buttons["racket.storage.continue"].waitForExistence(timeout: 6))
        app.buttons["racket.storage.continue"].tap()
        let stop = app.buttons["racket.rec.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "recording everything")

        XCUIDevice.shared.system.open(URL(string: "snappet://workout")!)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(stop.waitForExistence(timeout: 4), "still on the recording screen")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"), "still recording")
        XCTAssertFalse(app.alerts.firstMatch.exists, "nothing to say: the workout is already on screen")
        shot("08-live-activity-keeps-recording")

        // Its own Stop still ends it properly (the split prompt).
        stop.tap()
        XCTAssertTrue(any("racket.split.recorded").waitForExistence(timeout: 6), "the split prompt")
    }
}
