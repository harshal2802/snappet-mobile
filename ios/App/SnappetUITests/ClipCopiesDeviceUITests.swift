import XCTest

/// Prompts 274–276, device leg: open "Manage copies" and the "Free up space" chooser on a phone with
/// real copies in Google Drive, and check they render and add up. LOOK ONLY: it never taps a button
/// that removes, frees, copies or switches anything, and stops before every confirmation.
///
///     TEST_RUNNER_SNAPPET_DEVICE_CLIP_COPIES=1 xcodebuild test -scheme Snappet \
///       -destination 'id=<device udid>' -allowProvisioningUpdates \
///       -only-testing:SnappetUITests/ClipCopiesDeviceUITests
@MainActor final class ClipCopiesDeviceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func find(_ app: XCUIApplication, _ id: String, swipes: Int = 8) -> XCUIElement {
        let element = app.descendants(matching: .any)[id].firstMatch
        var left = swipes
        while !(element.exists && element.isHittable) && left > 0 { app.swipeUp(); left -= 1 }
        return element
    }

    func testManageCopiesAndTheFreeUpChooserRenderOnARealPhone() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs real copies in a real Google Drive — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_CLIP_COPIES"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_CLIP_COPIES=1; runs against the phone's real store, look only")
        }
        let app = XCUIApplication()
        app.launch()
        let apps = app.tabBars.buttons["Apps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 30))
        apps.tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let manage = find(app, "mediaVault.manage")
        XCTAssertTrue(manage.waitForExistence(timeout: 20), "no Manage copies row — are clip copies started?")
        shot("1 clip copies section")
        manage.tap()

        let summary = app.descendants(matching: .any)["mediaVault.freeUp.summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        sleep(4)   // the count arrives after a look at Photos
        print("DEVICE-COPIES summary: \(summary.label)")
        shot("2 manage copies")

        let freeUp = app.descendants(matching: .any)["mediaVault.freeUp"].firstMatch
        XCTAssertTrue(freeUp.waitForExistence(timeout: 5))
        guard freeUp.isEnabled else {
            let status = app.descendants(matching: .any)["mediaVault.manage.status"].firstMatch
            throw XCTSkip("Free up space is disabled (a copy pass is running or nothing is copied) — status: \(status.exists ? status.label : "none")")
        }
        freeUp.tap()

        let total = app.descendants(matching: .any)["mediaVault.freeUp.total"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 30), "the chooser did not list anything")
        print("DEVICE-COPIES chooser total: \(total.label)")
        XCTAssertNotEqual(total.label, "Nothing matches.", "everything is selected to begin with")
        shot("3 free up chooser")

        // Unticking an activity changes the total (still nothing removed).
        let activity = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'mediaVault.freeUp.activity.'")).firstMatch
        if activity.exists {
            activity.tap()
            print("DEVICE-COPIES after unticking \(activity.identifier): \(total.label)")
            shot("4 one activity unticked")
            activity.tap()
        }

        let sessions = find(app, "mediaVault.freeUp.sessions", swipes: 3)
        XCTAssertTrue(sessions.exists)
        sessions.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mediaVault.freeUp.sessions.all"].firstMatch.waitForExistence(timeout: 10))
        shot("5 sessions")
        app.navigationBars.buttons.firstMatch.tap()

        // The button that would start a removal exists and is NOT tapped.
        XCTAssertTrue(find(app, "mediaVault.freeUp.go", swipes: 3).exists)
        #endif
    }

    /// "Remove all copies" asks first, and the question can be declined. Taps Cancel — never the red button.
    func testRemoveAllCopiesAsksAndCanBeCancelled() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs real copies in a real Google Drive — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_CLIP_COPIES"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_CLIP_COPIES=1; look only")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-vaultHoldCopies", "YES"]   // the button is disabled while a copy pass runs
        app.launch()
        let apps = app.tabBars.buttons["Apps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 30))
        apps.tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let manage = find(app, "mediaVault.manage")
        XCTAssertTrue(manage.waitForExistence(timeout: 20))
        manage.tap()
        let removeAll = app.descendants(matching: .any)["mediaVault.removeAll"].firstMatch
        XCTAssertTrue(removeAll.waitForExistence(timeout: 15))
        sleep(4)
        guard removeAll.isEnabled else { throw XCTSkip("Remove all copies is disabled (a copy pass is running)") }
        removeAll.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the question is not an alert")
        print("DEVICE-COPIES remove-all asks: \(alert.label) buttons: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        shot("remove all, asked")
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "no Cancel — tapping nothing")
        guard cancel.exists else { return }
        cancel.tap()
        sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let summary = app.descendants(matching: .any)["mediaVault.freeUp.summary"].firstMatch
        print("DEVICE-COPIES after Cancel: \(summary.exists ? summary.label : "no summary")")
        #endif
    }

    /// Prompt 278 on a phone: the standing "Find missing clips" row opens the list, and the cloud
    /// restore question can be cancelled. Look only — taps Done and Cancel, never a red button.
    func testFindMissingClipsRowAndRestoreQuestionCanBeCancelled() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_CLIP_COPIES"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_CLIP_COPIES=1; look only")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-vaultHoldCopies", "YES"]
        app.launch()
        let apps = app.tabBars.buttons["Apps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 30))
        apps.tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        sleep(8)   // the look at Photos that counts what is missing
        let keep = app.switches["mediaVault.keepCopies"].firstMatch
        let keepBefore = keep.exists ? "\(keep.value ?? "")" : "absent"
        defer {
            for _ in 0..<6 where !(keep.exists && keep.isHittable) { app.swipeDown() }
            let keepAfter = keep.exists ? "\(keep.value ?? "")" : "absent"
            print("DEVICE-COPIES copies switch before=\(keepBefore) after=\(keepAfter)")
            XCTAssertEqual(keepBefore, keepAfter, "a look-only check changed the copies switch")
        }

        let row = find(app, "backup.findMissingClips")
        XCTAssertTrue(row.exists, "no Find missing clips row")
        if row.exists {
            print("DEVICE-COPIES missing row: \(row.label)")
            shot("find missing clips row")
            row.tap()
            let done = app.buttons["clips.missing.done"]
            sleep(3)
            shot("3s after tapping the row")
            let started = Date()
            XCTAssertTrue(done.waitForExistence(timeout: 60), "the list did not open")
            print("DEVICE-COPIES list appeared after \(Int(Date().timeIntervalSince(started)) + 3)s")
            sleep(2)
            print("DEVICE-COPIES list title: \(app.navigationBars.allElementsBoundByIndex.map(\.identifier)) rows on screen: \(app.descendants(matching: .any).matching(identifier: "clips.missing.row").count)")
            shot("missing clips list")
            if done.exists { done.tap() }
            sleep(2)
        }

        // The cloud restore question: open it for the newest backup and decline.
        for _ in 0..<6 { app.swipeDown() }
        let list = find(app, "cloudBackup.restoreList")
        guard list.exists else { print("DEVICE-COPIES no cloud backup list on this phone"); return }
        list.tap()
        let backup = app.buttons["cloudBackup.restore.row"].firstMatch
        guard backup.waitForExistence(timeout: 60) else { print("DEVICE-COPIES no cloud backup listed"); return }
        backup.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the restore question is not an alert")
        print("DEVICE-COPIES restore asks: \(alert.label) buttons: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        shot("replace all data, asked")
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "no Cancel — tapping nothing")
        if cancel.exists { cancel.tap() }
        sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        #endif
    }

    /// Puts "Keep clip copies in Google Drive" back ON after a check left it off. Only ever turns
    /// it on, and only when `SNAPPET_DEVICE_RESTORE_COPIES=1`.
    func testTurnClipCopiesBackOn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_RESTORE_COPIES"] == "1" else {
            throw XCTSkip("opt-in: set SNAPPET_DEVICE_RESTORE_COPIES=1")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-vaultHoldCopies", "YES"]
        app.launch()
        let apps = app.tabBars.buttons["Apps"]
        XCTAssertTrue(apps.waitForExistence(timeout: 30))
        apps.tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let keep = app.switches["mediaVault.keepCopies"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 20))
        sleep(6)
        print("DEVICE-COPIES copies switch was: \(keep.value ?? "")")
        if "\(keep.value ?? "")" == "0" {
            keep.switches.firstMatch.exists ? keep.switches.firstMatch.tap() : keep.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            sleep(3)
        }
        print("DEVICE-COPIES copies switch is now: \(keep.value ?? "")")
        shot("copies switch restored")
        XCTAssertEqual("\(keep.value ?? "")", "1")
        #endif
    }
}
