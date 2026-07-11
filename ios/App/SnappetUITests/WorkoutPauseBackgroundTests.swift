import XCTest

/// UI coverage for this branch's new live-workout surfaces — the ones the broader
/// `WorkoutWalkthroughTests` (A2/A4 overlay) doesn't exercise:
///   • **Pause / Resume** from the player's toolbar control (the on-wrist + Live-Activity
///     pause is relayed; here we assert the *player's* state via the control's label flip,
///     since the timer header ignores its children for accessibility).
///   • **Minimize → in-app live banner**: leaving the player without ending the workout drops
///     the full-screen cover and reveals the persistent `LiveWorkoutBanner`.
///   • **Banner → resume**: tapping the banner zooms back into the player.
///
/// Drives the same fresh-store path as the rest of SnappetUITests so the run is deterministic
/// and never inherits a leftover active session.
final class WorkoutPauseBackgroundTests: XCTestCase {
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

    /// Wait until `el`'s accessibility label equals `expected` (used for the Pause↔Resume flip).
    private func waitForLabel(_ el: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Navigate Apps → Workout → Routines → a routine → Start Workout, landing in the player.
    private func openPlayer() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the workout module card should be in the App Library")
        card.tap()

        let routines = app.segmentedControls.buttons["Routines"]
        XCTAssertTrue(routines.waitForExistence(timeout: 6), "the Routines section should be reachable")
        routines.tap()

        let row = app.buttons.matching(identifier: "routineRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "a starter routine row should be present")
        row.tap()

        let start = app.buttons["Start Workout"]
        XCTAssertTrue(start.waitForExistence(timeout: 6), "routine detail should offer Start Workout")
        start.tap()

        XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 8)
            || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 2),
            "the player should show the overall workout timer")
    }

    func testPauseResumeMinimizeAndBanner() {
        openPlayer()
        snap("01-player")

        // --- Pause / Resume (the toolbar control's label flips Pause ↔ Resume) ---
        let pause = app.buttons["pauseWorkout"]
        XCTAssertTrue(pause.waitForExistence(timeout: 6), "the player should show a Pause control")
        XCTAssertEqual(pause.label, "Pause", "the control should read 'Pause' while running")

        pause.tap()
        XCTAssertTrue(waitForLabel(pause, "Resume"), "pausing should flip the control to 'Resume'")
        snap("02-paused")

        pause.tap()
        XCTAssertTrue(waitForLabel(pause, "Pause"), "resuming should flip the control back to 'Pause'")

        // --- Minimize → the in-app live banner appears (workout keeps running) ---
        let minimize = app.buttons["minimizeWorkout"]
        XCTAssertTrue(minimize.waitForExistence(timeout: 4), "the player should show a Minimize control")
        minimize.tap()

        let banner = app.buttons["liveWorkoutBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 6),
                      "minimizing should reveal the persistent live-workout banner")
        // The player cover is gone while minimized.
        XCTAssertFalse(app.buttons["pauseWorkout"].exists, "the player cover should be dismissed while minimized")
        snap("03-banner")

        // --- Banner → resume (zoom back into the player) ---
        // The banner floats over the scrollable routines list (safeAreaInset), so a plain
        // center tap can resolve onto a routine row sitting behind the bar. Tap low in the
        // banner's frame — squarely on the visible bar, below any overlapped row. One-shot
        // coordinate taps can be swallowed under full-suite load (frames settle late), so if
        // the player didn't come back and the banner is still up, tap once more at the bar's
        // centre — a genuinely broken tap-through still fails both attempts.
        banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        if !app.buttons["pauseWorkout"].waitForExistence(timeout: 6), banner.exists {
            banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["pauseWorkout"].waitForExistence(timeout: 6),
                      "tapping the banner should bring the player back")
        XCTAssertFalse(banner.exists, "the banner should hide once the player is foregrounded again")
        snap("04-back-in-player")

        // --- Clean up: finish + discard so no active session leaks into other tests ---
        // The pager's always-available Finish opens the completion summary; from there "Discard
        // workout" (then the confirm) throws the (empty) session away. (No guided "End" toolbar item.)
        app.buttons["freeform.finish"].tap()
        let discard = app.buttons["freeform.discard"]
        if discard.waitForExistence(timeout: 4) {
            discard.tap()
            let confirm = app.buttons["Discard (don't save)"]
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        }
    }
}
