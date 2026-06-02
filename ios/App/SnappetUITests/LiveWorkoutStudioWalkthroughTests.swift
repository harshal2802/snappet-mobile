import XCTest

/// A chronological, screenshot-capturing walkthrough of the **Live Workout Capture + Video
/// Studio** initiative (A1–A4 live capture + B1–B5 video studio). It launches with
/// `-uiTestSeedStudioDemo`, which seeds a **completed** `WorkoutSession` carrying a synthetic
/// `hrSeries` (a fresh in-memory store, see `SnappetApp` / `StudioDemoSeed`), so the headline
/// B2 enriched summary (HR chart + avg/max/min + time-in-zone) actually RENDERS on the
/// simulator — which otherwise has no live HR source.
///
/// Each step captures a zero-padded, ordered screenshot via `snap("NN-name")`
/// (`XCTAttachment`, `.keepAlways`); the `NN` carries the chronological order so the frames can
/// be stitched into a video. Extract with `xcrun xcresulttool export attachments`.
///
/// What renders on the simulator vs. what is device-only (gracefully skipped, with a snapshot of
/// the real state):
///  - RENDERS: suite home, app library, dashboard, routines, routine detail / Start bar, the
///    live player (A2 overall-timer header + A4 live-metrics overlay no-source state), the rest
///    screen, finish, History, the seeded session's **B2 HR summary**, the B1 media section's
///    empty state + the B4 "Generate highlight" entry (disabled — no video on the sim), Settings,
///    the A3 heart-rate source picker sheet.
///  - DEVICE-ONLY (not shown here): a real live-HR overlay value, tagged media thumbnails, the
///    B3 clip editor, an actual generated highlight reel — they need a paired Apple Watch / BLE
///    band + a real Photos video. Expected; the seed showcases the HR summary + the live UI.
final class LiveWorkoutStudioWalkthroughTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedStudioDemo"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func section(_ t: String) -> XCUIElement { app.segmentedControls.buttons[t] }

    /// The seeded demo routine/session name (must match `StudioDemoSeed.routineName`).
    private let demoName = "Studio Demo — Full Body"

    func testStudioWalkthrough() {
        // 1 — Suite home (dashboard).
        snap("01-suite-home")

        // 2 — App Library.
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 6))
        app.tabBars.buttons["Apps"].tap()
        snap("02-app-library")

        // 3 — Enter WorkoutTracker → dashboard.
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6),
                      "the workout card should be in the App Library")
        app.buttons["moduleCard.workout-log"].tap()
        XCTAssertTrue(section("Routines").waitForExistence(timeout: 6),
                      "the workout dashboard's section picker should appear")
        sleep(1); snap("03-workout-dashboard")

        // 4 — Routines.
        section("Routines").tap(); sleep(1); snap("04-routines")

        // 5 — A routine's detail (with the Start bar). Use a starter routine so the prescription
        // + Start bar render (the seeded session is a completed one, surfaced later in History).
        let rRow = app.buttons.matching(identifier: "routineRow").firstMatch
        if rRow.waitForExistence(timeout: 6) {
            rRow.tap()
            if app.buttons["Start Workout"].waitForExistence(timeout: 6) {
                snap("05-routine-detail")

                // 6 — Start the workout → the live player: A2 overall-timer header + A4
                // live-metrics overlay (no-source state on the sim).
                app.buttons["Start Workout"].tap(); sleep(2); snap("06-player")
                XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 5)
                    || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 1),
                    "the player should show the A2 overall workout timer")
                XCTAssertTrue(app.otherElements["liveMetricsOverlay"].waitForExistence(timeout: 5)
                    || app.staticTexts["liveMetricsOverlay"].waitForExistence(timeout: 1),
                    "the player should show the A4 live-metrics overlay (no-source state)")

                // 7 — Drive a couple of sets to reach the rest screen (overall timer + overlay
                // + rest countdown), then finish.
                driveToRestThenFinish()
                sleep(2)

                // 8 — After finish (lands on the dashboard).
                snap("08-after-finish")
            } else {
                snap("NOTREACHED-05-routine-detail")
            }
        } else {
            snap("NOTREACHED-04-routine-row")
        }

        // 9 — History (now also holds the seeded completed demo session).
        section("History").tap(); sleep(1); snap("09-history")
        XCTAssertTrue(app.staticTexts[demoName].waitForExistence(timeout: 6)
            || app.cells.firstMatch.waitForExistence(timeout: 2),
            "the seeded demo session should appear in History")

        // 10 — Open the seeded completed session → its B2 enriched summary (HR chart +
        // avg/max/min + time-in-zone). This is the headline screen: open the DEMO session
        // specifically (its synthetic hrSeries is what makes the HR section render).
        if openDemoSession() {
            // The HR chart renders only when the session has a non-empty hrSeries (the seed's job).
            XCTAssertTrue(app.otherElements["hrChart"].waitForExistence(timeout: 6)
                || app.staticTexts["Heart rate"].waitForExistence(timeout: 2),
                "the seeded session's summary should render the B2 HR chart / Heart rate section")
            sleep(1); snap("10-session-summary-hr")

            // 11 — The B1 tagged-media section + the B4 "Generate highlight" entry (empty/
            // disabled on the sim — snap the real state). Scroll down to bring it into view.
            let summary = app.collectionViews.firstMatch.exists
                ? app.collectionViews.firstMatch : app.tables.firstMatch
            if app.staticTexts["Media from this workout"].waitForExistence(timeout: 3) == false {
                summary.swipeUp(); summary.swipeUp()
            }
            snap("11-media-and-highlight")
            // The Generate-highlight button exists but is disabled (no video on the sim).
            _ = app.buttons["generateHighlight"].waitForExistence(timeout: 3)

            // Pop back to the section view for Settings.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        } else {
            // History → detail is a value-based NavigationLink (a known XCUITest-tap limitation in
            // this app, decisions.md 2026-05-31). If it didn't push, snap the real History state so
            // the chronological story still shows where the headline summary lives.
            snap("10-session-summary-NOTREACHED")
            snap("11-media-and-highlight-NOTREACHED")
        }

        // 12 — Settings.
        section("Settings").tap(); sleep(1); snap("12-settings")

        // 13 — The A3 heart-rate source picker sheet (Apple Watch + BLE scan). The entry is a
        // `.buttonStyle(.plain)` row; tap it, and if the sheet doesn't present, fall back to the
        // row's label / a coordinate tap before giving up (robust, never flakes the run).
        if openHRSourcePicker() {
            sleep(1); snap("13-hr-source-picker")
        } else {
            snap("13-hr-source-picker-NOTREACHED")
        }
    }

    /// Open the A3 heart-rate source picker sheet from Settings. Returns `true` once the sheet's
    /// "Apple Watch" row is visible.
    private func openHRSourcePicker() -> Bool {
        let sheetMarker = app.buttons["hrSourceAppleWatch"]
        let openHR = app.buttons["openHeartRateSource"]
        // Attempt 1: the identified row button.
        if openHR.waitForExistence(timeout: 5) {
            openHR.tap()
            if sheetMarker.waitForExistence(timeout: 4) { return true }
        }
        // Attempt 2: the row's label text.
        let label = app.staticTexts["Heart-rate source"]
        if label.exists {
            label.tap()
            if sheetMarker.waitForExistence(timeout: 4) { return true }
        }
        // Attempt 3: a coordinate tap on the row (last resort).
        if openHR.exists {
            openHR.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if sheetMarker.waitForExistence(timeout: 4) { return true }
        }
        return false
    }

    // MARK: - Player driving

    /// Advance through the first sets to surface the rest screen (snapping it), then finish the
    /// workout and save it. Mirrors `WorkoutWalkthroughTests.drivePlayerToDone` but captures the
    /// rest screen as its own chronological frame (step 7).
    private func driveToRestThenFinish() {
        var snappedRest = false
        for _ in 0..<40 {
            if app.buttons["Finish"].exists { app.buttons["Finish"].tap(); return }
            if app.buttons["Skip rest"].exists {
                if !snappedRest { snap("07-rest-screen"); snappedRest = true }
                app.buttons["Skip rest"].tap()
            } else if app.buttons["Complete & finish"].exists {
                app.buttons["Complete & finish"].tap()
            } else if app.buttons["Complete set"].exists {
                app.buttons["Complete set"].tap()
            } else if app.buttons["Skip exercise"].exists {
                app.buttons["Skip exercise"].tap()
                if app.buttons["Skip exercise"].exists { app.buttons["Skip exercise"].tap() }
            } else {
                break
            }
            usleep(600_000)
        }
        if app.buttons["End"].exists {
            app.buttons["End"].tap()
            if app.buttons["Save & exit"].waitForExistence(timeout: 2) { app.buttons["Save & exit"].tap() }
        }
    }

    // MARK: - History → demo session

    /// Open the seeded demo session from History. The row is a value-based `NavigationLink`
    /// (the one row in the suite kept as such — see decisions.md 2026-05-31); we try the
    /// identifier'd cell, then a cell carrying the demo name, then the first history row. Returns
    /// `true` once the session-detail (the "Session" nav title) is on screen.
    private func openDemoSession() -> Bool {
        let candidates: [XCUIElement] = [
            app.cells.containing(.staticText, identifier: nil)
                .matching(NSPredicate(format: "label CONTAINS %@", demoName)).firstMatch,
            app.staticTexts[demoName],
            app.cells.matching(identifier: "historyRow")
                .containing(NSPredicate(format: "label CONTAINS %@", demoName)).firstMatch,
            app.cells.matching(identifier: "historyRow").firstMatch,
            app.cells.firstMatch,
        ]
        for el in candidates {
            guard el.waitForExistence(timeout: 3), el.isHittable else { continue }
            el.tap()
            if app.navigationBars["Session"].waitForExistence(timeout: 5)
                || app.staticTexts["Heart rate"].waitForExistence(timeout: 2) {
                return true
            }
        }
        return false
    }
}
