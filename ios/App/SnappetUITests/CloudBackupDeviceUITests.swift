import XCTest

/// Prompt 267, device leg: automatic backup against REAL iCloud. The simulator has no iCloud account
/// under test, so this is device-only and opt-in. It runs against the phone's real store: it switches
/// "Back up to" to iCloud (the setting the user asked to try), waits for the first backup, and checks
/// the backup is listed. It never restores, and never edits or deletes app data.
///
///     TEST_RUNNER_SNAPPET_DEVICE_CLOUD_BACKUP=1 xcodebuild test -scheme Snappet \
///       -destination 'id=<device udid>' -allowProvisioningUpdates \
///       -only-testing:SnappetUITests/CloudBackupDeviceUITests
@MainActor final class CloudBackupDeviceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testICloudBackupRunsAndIsListedOnARealAccount() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs a real iCloud account — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_CLOUD_BACKUP"] == "1" else {
            throw XCTSkip("opt-in: runs against the phone's real store and turns on iCloud backup")
        }
        let app = XCUIApplication()
        app.launch()
        let apps = app.tabBars.buttons["Apps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 30))
        apps.tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let destination = app.descendants(matching: .any)["cloudBackup.destination"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()
        let iCloud = app.buttons["iCloud"]
        XCTAssertTrue(iCloud.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Google Drive"].exists, "this build carries a Google client ID")
        iCloud.tap()

        // Optionally force a fresh backup (SNAPPET_DEVICE_CLOUD_BACKUP_NOW=1) and wait for it to finish.
        if ProcessInfo.processInfo.environment["SNAPPET_DEVICE_CLOUD_BACKUP_NOW"] == "1" {
            let now = app.buttons["cloudBackup.now"]
            XCTAssertTrue(now.waitForExistence(timeout: 10))
            now.tap()
            let working = app.staticTexts["Backing up…"]
            _ = working.waitForExistence(timeout: 20)
            let deadline = Date().addingTimeInterval(600)
            while working.exists && Date() < deadline { sleep(2) }
            XCTAssertFalse(working.exists, "still backing up after 10 min")
            print("DEVICE-BACKUP status after Back up now: \(statusText(app))")
        }

        // A real upload of the whole store: give it minutes, and report what the status row says.
        let last = app.staticTexts["Last backup"]
        let done = last.waitForExistence(timeout: 300)
        XCTAssertTrue(done, "no 'Last backup' after 5 min — status says: \(statusText(app))")

        let list = app.buttons["cloudBackup.restoreList"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.tap()
        let row = app.buttons["cloudBackup.restore.row"].firstMatch
        let listed = row.waitForExistence(timeout: 60)
        let problem = app.descendants(matching: .any)["cloudBackup.restore.problem"].firstMatch
        XCTAssertTrue(listed, "the backup is not listed — empty: \(app.staticTexts["cloudBackup.restore.empty"].exists), problem: \(problem.exists ? problem.label : "none")")
        // Deliberately stop here: tapping a row leads to "Replace everything".
        #endif
    }

    private func statusText(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).matching(identifier: "cloudBackup.status")
        return (0..<nodes.count).map { nodes.element(boundBy: $0).label }.joined(separator: " | ")
    }
}
