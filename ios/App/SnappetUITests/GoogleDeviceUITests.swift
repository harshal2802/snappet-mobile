import XCTest

/// Prompt 268, device leg: sign in to a REAL Google account and back up to its Drive. Google's sheet
/// cannot be reached on the simulator under test, so this is device-only and opt-in. It runs against
/// the phone's real store: it switches "Back up to" to Google Drive, signs in with the account named
/// in SNAPPET_DEVICE_GOOGLE_EMAIL (which must already be signed in to Google in Safari — this test
/// never types a password and stops if one is asked for), waits for the first backup, and checks it is
/// listed. It never restores, and never edits or deletes app data.
///
///     TEST_RUNNER_SNAPPET_DEVICE_GOOGLE_EMAIL=you@gmail.com xcodebuild test -scheme Snappet \
///       -destination 'id=<device udid>' -allowProvisioningUpdates \
///       -only-testing:SnappetUITests/GoogleDeviceUITests
@MainActor final class GoogleDeviceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testGoogleSignInAndDriveBackupOnARealAccount() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs Google's real sign-in sheet — device only")
        #else
        guard let email = ProcessInfo.processInfo.environment["SNAPPET_DEVICE_GOOGLE_EMAIL"], !email.isEmpty else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_GOOGLE_EMAIL; runs against the phone's real store")
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
        let drive = app.buttons["Google Drive"]
        XCTAssertTrue(drive.waitForExistence(timeout: 5))
        drive.tap()

        let account = app.descendants(matching: .any)["google.account"].firstMatch
        let signIn = app.buttons["google.signIn"]
        if !account.waitForExistence(timeout: 4) {
            XCTAssertTrue(signIn.waitForExistence(timeout: 5), "neither signed in nor a sign-in button")
            signIn.tap()
            try driveGoogleSheet(app: app, email: email, until: account)
        }
        XCTAssertTrue(account.waitForExistence(timeout: 30), "not signed in — \(visible(app))")
        print("DEVICE-GOOGLE account row: \(account.label) / \(String(describing: account.value))")

        // The first Drive backup starts on sign-in; a real upload of the whole store.
        let working = app.staticTexts["Backing up…"]
        _ = working.waitForExistence(timeout: 15)
        let deadline = Date().addingTimeInterval(900)
        while working.exists && Date() < deadline { sleep(3) }
        print("DEVICE-GOOGLE status: \(statusText(app))")
        XCTAssertTrue(app.staticTexts["Last backup"].waitForExistence(timeout: 30), "no backup — status: \(statusText(app))")

        let list = app.buttons["cloudBackup.restoreList"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.tap()
        let row = app.buttons["cloudBackup.restore.row"].firstMatch
        let listed = row.waitForExistence(timeout: 90)
        let problem = app.descendants(matching: .any)["cloudBackup.restore.problem"].firstMatch
        XCTAssertTrue(listed, "the Drive backup is not listed — problem: \(problem.exists ? problem.label : "none")")
        print("DEVICE-GOOGLE listed: \(row.label)")
        // Deliberately stop here: tapping a row leads to "Replace everything".
        #endif
    }

    /// Walk Google's sheet: the system "wants to use google.com" alert, the account chooser, the
    /// unverified-app notice and the consent page. Prints what each page shows; never types a password.
    private func driveGoogleSheet(app: XCUIApplication, email: String, until done: XCUIElement) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Continue"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }

        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        for step in 0..<12 {
            if done.exists { return }
            sleep(4)
            if done.exists { return }
            let page = safari.webViews.firstMatch.exists ? safari : app
            print("DEVICE-GOOGLE step \(step) [\(page === safari ? "safari" : "app")]: \(visible(page))")
            if page.secureTextFields.firstMatch.exists {
                XCTFail("Google is asking for a password — sign in to \(email) in Safari first, then re-run")
                return
            }
            let mine = page.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", email)).allElementsBoundByIndex.last
            let titles = ["Continue", "Allow", "Next"]
            if page.textFields.firstMatch.exists, !(mine?.exists ?? false) {
                let field = page.textFields.firstMatch
                field.tap()
                field.typeText(email)
                if page.buttons["Next"].exists { page.buttons["Next"].tap() }
            } else if let mine, mine.exists, !titles.contains(where: { page.buttons[$0].exists }) {
                mine.tap()
            } else if let title = titles.first(where: { page.buttons[$0].exists }) {
                page.buttons[title].firstMatch.tap()
            } else if let mine, mine.exists {
                mine.tap()
            }
        }
    }

    private func visible(_ app: XCUIApplication) -> String {
        func labels(_ query: XCUIElementQuery, _ kind: String) -> String {
            let found = query.allElementsBoundByIndex.prefix(18).map(\.label).filter { !$0.isEmpty }
            return "\(kind)=\(found)"
        }
        return [labels(app.webViews.buttons, "buttons"), labels(app.webViews.links, "links"),
                labels(app.webViews.staticTexts, "texts"),
                "textFields=\(app.webViews.textFields.count)", "secure=\(app.webViews.secureTextFields.count)",
                labels(app.staticTexts.matching(identifier: "google.failure"), "failure")].joined(separator: " ")
    }

    private func statusText(_ app: XCUIApplication) -> String {
        let nodes = app.descendants(matching: .any).matching(identifier: "cloudBackup.status")
        return (0..<nodes.count).map { nodes.element(boundBy: $0).label }.joined(separator: " | ")
    }
}
