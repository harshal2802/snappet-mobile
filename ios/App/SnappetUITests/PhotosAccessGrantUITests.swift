import XCTest

/// Gives the app full Photos access on this simulator, by answering the system's dialog (prompt 322
/// follow-up). On the iOS 26.5 simulator `simctl privacy … grant photos` is stored but PhotoKit still
/// reports "not determined", so a tap is the only way. `ClipBakePhotosIsolationTests` (unit tests) need
/// the access; CI runs this test, then them, in the SnappetTests leg.
///
/// It does nothing unless `SNAPPET_GRANT_PHOTOS` is set (CI passes `TEST_RUNNER_SNAPPET_GRANT_PHOTOS=1`):
/// in the ordinary UI legs, full access would change what other tests see.
@MainActor
final class PhotosAccessGrantUITests: XCTestCase {

    func testGrantFullPhotosAccess() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SNAPPET_GRANT_PHOTOS"] == "1",
                          "Grants Photos access only when SNAPPET_GRANT_PHOTOS=1 (CI's Photos step)")
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestRequestPhotosAccess"]
        app.launch()

        // The dialog belongs to the system, not the app. Already granted (a rerun) → no dialog, nothing to do.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Allow Full Access", "Allow Access to All Photos"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for label in labels {
                let button = springboard.buttons[label]
                if button.exists {
                    button.tap()
                    XCTAssertTrue(button.waitForNonExistence(timeout: 10), "the Photos dialog closes")
                    return
                }
            }
            if springboard.alerts.firstMatch.exists, !labels.contains(where: { springboard.buttons[$0].exists }) {
                XCTFail("unexpected system dialog: \(springboard.alerts.firstMatch.label) "
                        + "\(springboard.alerts.firstMatch.buttons.allElementsBoundByIndex.map { $0.label })")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // No dialog in 20 s: fine only if access was already given (the isolation tests check it themselves).
        print("PhotosAccessGrantUITests: no Photos dialog appeared (access already decided)")
    }
}
