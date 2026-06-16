import XCTest

/// App Store screenshot capture. Two modes:
/// - **Simulator** (`fastlane snapshot`, sets `FASTLANE_SNAPSHOT=YES`): seeds the Studio demo + bypasses
///   onboarding, and writes PNGs via `snapshot()` — but the sim has no HealthKit/Photos, so the
///   flagship reels can't render there.
/// - **Device** (plain `xcodebuild test`): uses your REAL data (no seed, already onboarded) and saves
///   each screen as an `XCTAttachment` (extracted from the .xcresult). This is how the flagship
///   reels / workout summary get captured with real footage.
@MainActor
final class SnappetScreenshots: XCTestCase {

    private var isFastlane: Bool { ProcessInfo.processInfo.environment["FASTLANE_SNAPSHOT"] == "YES" }

    override func setUpWithError() throws { continueAfterFailure = true }

    func testCaptureAppStoreScreenshots() {
        let app = XCUIApplication()
        if isFastlane {
            setupSnapshot(app)
            app.launchArguments += ["-uiTestSeedStudioDemo", "-snappet.hasOnboarded", "YES"]
        }
        app.launch()

        shot(app, "01-Home")

        // App Library + the flagship hero.
        if app.tabBars.buttons["Apps"].waitForExistence(timeout: 12) {
            app.tabBars.buttons["Apps"].tap()
            _ = app.buttons["appLibrary.flagship"].waitForExistence(timeout: 6)
            shot(app, "02-AppLibrary")

            // The flagship: Workout Reels. On device this lands on the real reels surface.
            let flagship = app.buttons["appLibrary.flagship"]
            if flagship.exists {
                flagship.tap()
                _ = app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 8)
                shot(app, "03-WorkoutReels")
                if app.navigationBars.buttons["BackButton"].exists { app.navigationBars.buttons["BackButton"].tap() }
            }
        }

        captureApp(app, "workout", "04-GymTracker")
        captureApp(app, "pomodoro", "05-Pomodoro")
        captureApp(app, "habit", "06-Habits")
    }

    /// Open a module from its App Library card, screenshot it, return to the grid top.
    private func captureApp(_ app: XCUIApplication, _ id: String, _ name: String) {
        if app.tabBars.buttons["Apps"].exists { app.tabBars.buttons["Apps"].tap() }
        let card = app.scrollToModuleCard(id)
        guard card.waitForExistence(timeout: 6) else { return }
        card.tap()
        _ = app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 8)
        shot(app, name)
        if app.navigationBars.buttons["BackButton"].exists { app.navigationBars.buttons["BackButton"].tap() }
        var up = 0
        while !app.buttons["moduleCard.workout"].exists && up < 8 { app.swipeDown(); up += 1 }
    }

    /// Capture: `snapshot()` on the sim (fastlane), an `XCTAttachment` on a device.
    private func shot(_ app: XCUIApplication, _ name: String) {
        if isFastlane {
            snapshot(name)
        } else {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
