import XCTest

/// Prompt 264: who owns the one live heart-rate source.
/// - F6: the Watch ending its workout reaches the phone (`-uiTestWatchEnded` plays the Watch's part: one sample, then
///   its `.ended` payload, decoded and handled as a received one). The phone session keeps running and says so.
/// - F7: a gym start while a Kilter board session is live is refused; the board session is untouched.
/// - F8: the heart-rate source can't be switched while a session is live.
final class HeartRateOwnershipUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
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

    private var timer: XCUIElement { any("overallWorkoutTimer") }

    private func openModule(_ card: String) {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Apps"].tap()
        let c = app.buttons["moduleCard.\(card)"]
        XCTAssertTrue(c.waitForExistence(timeout: 8), "the \(card) card should be in the App Library")
        c.tap()
    }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(b.waitForExistence(timeout: 4))
        b.tap()
    }

    /// Pop back to the App Library, however deep we are (never taps the Library's own leading button).
    private func backToApps() {
        for _ in 0..<5 {
            if app.navigationBars["Apps"].exists { return }
            back()
            _ = app.navigationBars["Apps"].waitForExistence(timeout: 2)
        }
        XCTAssertTrue(app.navigationBars["Apps"].exists, "back at the App Library")
    }

    private func quickStart() {
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 8), "Quick Start should be on the dashboard")
        quick.tap()
    }

    private func startBoardSession() {
        openModule("kilter")
        let start = app.buttons["kilter.session.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "the idle bar should offer Start session")
        start.tap()
        XCTAssertTrue(app.buttons["kilter.session.end"].waitForExistence(timeout: 4), "the board session is live")
    }

    /// Workout → Settings gear → Heart-rate source. Returns once the sheet's Apple Watch row is up.
    private func openHRSource() {
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 8), "the Settings gear should be in the toolbar")
        gear.tap()
        let open = app.buttons["openHeartRateSource"]
        XCTAssertTrue(open.waitForExistence(timeout: 6))
        // The row is a plain-style button around a LabeledContent: only its text takes a tap (the empty middle,
        // where XCUITest taps by default, does nothing), so tap over the "Heart-rate source" label.
        let marker = app.buttons["hrSourceAppleWatch"]
        for _ in 0..<3 where !marker.exists {
            open.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            _ = marker.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(marker.exists, "the picker should open")
    }

    private func closeHRSource() {
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["openHeartRateSource"].waitForExistence(timeout: 4))
        back()
    }

    // MARK: F6

    func testWatchEndingItsWorkoutKeepsThePhoneSessionRunningAndSaysSo() {
        app.launchArguments += ["-uiTestFreshStore", "-uiTestWatchEnded"]
        app.launch()
        openModule("workout-log")
        quickStart()
        XCTAssertTrue(timer.waitForExistence(timeout: 8), "the player should open")

        // The Watch's heart rate arrives first.
        XCTAssertTrue(any("freeform.hrChip").waitForExistence(timeout: 6), "the Watch's 128 bpm shows")
        shot("pr4-01-watch-streaming")

        // Then the Watch ends its workout: the notice says so, and no frozen bpm stays on screen.
        let notice = any("freeform.watchEndedNotice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "the player should say the Watch ended")
        XCTAssertTrue(app.staticTexts["Watch ended"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                             "This session is still running here")).firstMatch.exists)
        XCTAssertFalse(any("freeform.hrChip").exists, "no frozen heart rate")
        XCTAssertTrue(timer.exists, "the session keeps running")
        XCTAssertTrue(app.buttons["freeform.finish"].exists)
        shot("pr4-02-watch-ended-notice")

        // Keep going: the notice goes, a small chip stays, the session carries on.
        app.buttons["freeform.watchEndedKeepGoing"].tap()
        XCTAssertTrue(any("freeform.watchEndedChip").waitForExistence(timeout: 4), "the chip stays after Keep going")
        XCTAssertFalse(notice.exists)
        XCTAssertTrue(timer.exists)
        shot("pr4-03-watch-ended-chip")

        // Minimize and come back: still the same live session, still "Watch ended".
        app.buttons["minimizeWorkout"].tap()
        let banner = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "liveWorkoutBanner")).firstMatch
        if banner.waitForExistence(timeout: 4) { banner.tap() } else { quickStart() }   // Quick Start resumes it
        XCTAssertTrue(timer.waitForExistence(timeout: 6), "the same session is still live")
        XCTAssertTrue(any("freeform.watchEndedChip").waitForExistence(timeout: 4))
        XCTAssertFalse(any("freeform.watchEndedNotice").exists, "a dismissed notice stays dismissed")
    }

    // MARK: F7

    func testGymStartIsRefusedWhileABoardSessionIsLiveAndTheBoardSessionIsUntouched() {
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog"]
        app.launch()
        startBoardSession()
        backToApps()

        // Quick Start: refused with a plain message; no player opens.
        openModule("workout-log")
        quickStart()
        let alert = app.alerts["A board session is running"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the gym start should be refused")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                               "Finish it in Kilter Board first")).firstMatch.exists)
        shot("pr4-04-gym-start-refused")
        alert.buttons["OK"].tap()
        XCTAssertFalse(timer.waitForExistence(timeout: 2), "no gym session started")

        // A routine's Start Workout (a pushed screen) is refused the same way.
        let routines = app.segmentedControls.buttons["Routines"]
        XCTAssertTrue(routines.waitForExistence(timeout: 6))
        routines.tap()
        let row = app.buttons.matching(identifier: "routineRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        let start = app.buttons["Start Workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        start.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "a routine start is refused too")
        alert.buttons["OK"].tap()
        XCTAssertFalse(timer.waitForExistence(timeout: 2))
        backToApps()

        // The board session is untouched: still live; end it there, and the gym start goes through.
        openModule("kilter")
        XCTAssertTrue(app.buttons["kilter.session.end"].waitForExistence(timeout: 6), "the board session is still live")
        shot("pr4-05-board-session-untouched")
        app.buttons["kilter.session.end"].tap()
        XCTAssertTrue(app.buttons["kilter.session.start"].waitForExistence(timeout: 4))
        backToApps()
        openModule("workout-log")
        quickStart()
        XCTAssertTrue(timer.waitForExistence(timeout: 8), "with the board session finished, the gym start works")
        XCTAssertFalse(alert.exists)
    }

    // MARK: F8

    func testHeartRateSourceIsLockedWhileAWorkoutIsLive() {
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
        openModule("workout-log")

        // No session: the source can be switched.
        openHRSource()
        XCTAssertTrue(app.buttons["hrSourceAppleWatch"].isEnabled)
        XCTAssertFalse(any("hrSourceLocked").exists)
        shot("pr4-06-hr-source-unlocked")
        closeHRSource()

        // A live workout, minimized: Settings is reachable, but the source rows are off and say why.
        quickStart()
        XCTAssertTrue(timer.waitForExistence(timeout: 8))
        app.buttons["minimizeWorkout"].tap()
        openHRSource()
        XCTAssertTrue(any("hrSourceLocked").waitForExistence(timeout: 4), "the picker should say why it's locked")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                             "while a session is live")).firstMatch.exists)
        XCTAssertFalse(app.buttons["hrSourceAppleWatch"].isEnabled, "the source can't be switched mid-session")
        let prefer = any("hrSourcePreferBand")
        if prefer.exists { XCTAssertFalse(prefer.isEnabled, "the band preference changes the source too") }
        shot("pr4-07-hr-source-locked")
    }

    func testHeartRateSourceIsLockedWhileABoardSessionIsLive() {
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog"]
        app.launch()
        startBoardSession()
        backToApps()
        openModule("workout-log")
        openHRSource()
        XCTAssertTrue(any("hrSourceLocked").waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["hrSourceAppleWatch"].isEnabled)
        shot("pr4-08-hr-source-locked-board")
    }
}
