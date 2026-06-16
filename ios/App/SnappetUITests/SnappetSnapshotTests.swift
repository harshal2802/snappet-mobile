import XCTest

/// App Store screenshot capture for `fastlane snapshot` (run via the `screenshots` lane or
/// `fastlane snapshot`). Each test launches a fresh app with the right `-uiTest…` seed flag,
/// navigates to a screen, and calls `snapshot("NN-Name")`.
///
/// Only screens that render deterministically on the **Simulator** are captured. The reel/video
/// *preview* and BLE heart-rate need a real device (AVFoundation composition / CoreBluetooth), so
/// they're intentionally omitted — capture those manually on hardware if you want them.
///
/// Accessibility identifiers used here come from the app's real UI (see the existing
/// `*WalkthroughTests`). `setupSnapshot`/`snapshot` are provided by `SnapshotHelper.swift`.
final class SnappetSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Fresh app instance with the given seed args + fastlane's snapshot config applied.
    @MainActor private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += args
        setupSnapshot(app)          // must be called before launch()
        app.launch()
        return app
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    // MARK: Home dashboard + app library

    @MainActor func testHomeAndLibrary() {
        let app = launch(["-uiTestSeedStudioDemo"])   // populated home (stats + activity)
        snapshot("01-Home")

        app.tabBars.buttons["Apps"].tap()
        snapshot("02-Apps")
    }

    // MARK: Live workout — overall timer + live-HR pill

    @MainActor func testWorkoutPlayer() {
        let app = launch(["-uiTestFreshStore"])
        app.tabBars.buttons["Apps"].tap()
        tapIfExists(app.buttons["moduleCard.workout-log"])
        tapIfExists(app.segmentedControls.buttons["Routines"])
        tapIfExists(app.buttons.matching(identifier: "routineRow").firstMatch)
        if tapIfExists(app.buttons["Start Workout"]) {
            _ = app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 6)
            snapshot("03-Workout")
        }
    }

    // MARK: Session summary (HR chart) + video studio

    @MainActor func testHeartRateAndStudio() {
        let app = launch(["-uiTestSeedStudioDemo"])
        app.tabBars.buttons["Apps"].tap()
        tapIfExists(app.buttons["moduleCard.workout-log"])
        tapIfExists(app.segmentedControls.buttons["History"])
        let demo = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Studio Demo")).firstMatch
        if tapIfExists(demo) {
            snapshot("04-HeartRate")
            let openStudio = app.buttons["openStudio"]
            var swipes = 0
            while !openStudio.exists && swipes < 6 { app.swipeUp(); swipes += 1 }
            if tapIfExists(openStudio) {
                _ = app.buttons["studioPlayPause"].waitForExistence(timeout: 8)
                snapshot("05-Studio")
            }
        }
    }

    // MARK: Kilter climb detail — board schematic (synthetic catalog fixture)

    @MainActor func testKilterClimbDetail() {
        let app = launch(["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog"])
        let card = app.buttons["moduleCard.kilter"]
        var swipes = 0
        while !card.exists && swipes < 10 { app.swipeUp(); swipes += 1 }
        if tapIfExists(card), tapIfExists(app.buttons["kilter.climbRow"].firstMatch, timeout: 8) {
            snapshot("06-Kilter")
        }
    }
}
