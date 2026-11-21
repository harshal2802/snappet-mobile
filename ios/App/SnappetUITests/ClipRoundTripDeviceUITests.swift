import XCTest

/// Prompts 274–277, device leg: free ONE small copied clip from the phone, play it from Google
/// Drive and bring it back (the app's `-vaultRoundTripProbe`). This test only launches the app in
/// that mode and answers iOS's own "Allow Snappet to delete this video?" prompt; the outcome is
/// read from the app's preferences afterwards. The original stays in Recently Deleted for 30 days.
/// Opt-in, and only with the owner's say-so:
///
///     TEST_RUNNER_SNAPPET_DEVICE_ROUND_TRIP=1 xcodebuild test -scheme Snappet \
///       -destination 'id=<device udid>' -allowProvisioningUpdates \
///       -only-testing:SnappetUITests/ClipRoundTripDeviceUITests
@MainActor final class ClipRoundTripDeviceUITests: XCTestCase {

    func testFreeOneClipPlayItFromDriveAndBringItBack() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs real Photos and a real Google Drive — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_ROUND_TRIP"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_ROUND_TRIP=1; removes one original from Photos and brings it back")
        }
        let app = XCUIApplication()
        // SNAPPET_DEVICE_PROBE picks the in-app check: the round trip (default) or "-vaultExtrasProbe".
        app.launchArguments = [ProcessInfo.processInfo.environment["SNAPPET_DEVICE_PROBE"] ?? "-vaultRoundTripProbe"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var answered = false
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            for alerts in [springboard.alerts, app.alerts] where alerts.firstMatch.exists {
                let alert = alerts.firstMatch
                print("DEVICE-ROUNDTRIP alert: \(alert.label) buttons: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
                let delete = alert.buttons["Delete"]
                if delete.exists { delete.tap(); answered = true }
            }
            if answered { break }
            sleep(2)
        }
        XCTAssertTrue(answered, "iOS never asked to delete the clip — see mediaVault.roundTripProbe for why")
        sleep(75)   // the download from Drive and the save back into Photos
        #endif
    }
}
