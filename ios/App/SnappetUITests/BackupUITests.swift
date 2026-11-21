import XCTest

/// Issue #68 surfaces: the corrupt-store fallback is VISIBLE (driven by the
/// `-uiTestCorruptStore` launch hook — the real `try?` failure can't be forced from a
/// test) and offers recovery, and the suite backup sheet opens from the App Library.
/// The Files-picker round trip itself is system UI (not automatable here); the
/// serialize/restore contract is locked by `SnappetBackupTests`.
final class BackupUITests: XCTestCase {

    func testCorruptStoreShowsBannerAndRestoreOpensBackupSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestCorruptStore"]
        app.launchOnTestStore()

        // The banner is persistent and explicit — no more silent blank app.
        let restore = app.buttons["store.health.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10),
                      "the corrupt-store fallback must show the warning banner")
        XCTAssertTrue(app.staticTexts["Your data couldn't be opened"].exists)
        XCTAssertTrue(app.buttons["store.health.reset"].exists)

        // Restore-from-backup leads straight to the backup surface.
        restore.tap()
        XCTAssertTrue(app.buttons["backup.restore"].waitForExistence(timeout: 6))
        // In fallback every EXPORT path is gated off (the in-memory store is empty — a
        // "backup" of it would cover the user with 0 records); restore stays available.
        XCTAssertFalse(app.buttons["backup.export"].isEnabled)
        reveal(app.buttons["backup.export.feedback"], in: app)   // below the fold since prompt 267
        XCTAssertFalse(app.buttons["backup.export.journal"].isEnabled)
        XCTAssertFalse(app.buttons["backup.export.feedback"].isEnabled)
        XCTAssertTrue(app.buttons["backup.restore"].isEnabled)
        // Automatic backup can't be switched on over the empty fallback store either.
        app.swipeDown(); app.swipeDown()
        XCTAssertFalse(app.descendants(matching: .any)["cloudBackup.destination"].firstMatch.isEnabled)
        app.buttons["backup.done"].tap()

        // Reset asks before destroying anything.
        app.buttons["store.health.reset"].tap()
        XCTAssertTrue(app.buttons["store.health.confirmReset"].waitForExistence(timeout: 6))
    }

    func testBackupSheetOpensFromTheAppLibraryToolbar() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launchOnTestStore()
        app.tabBars.buttons["Apps"].tap()

        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        XCTAssertTrue(app.buttons["backup.export"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["backup.restore"].exists)
        reveal(app.buttons["backup.export.feedback"], in: app)   // below the fold since prompt 267
        XCTAssertTrue(app.buttons["backup.export.journal"].exists)
        XCTAssertTrue(app.buttons["backup.export.budget"].exists)
        XCTAssertTrue(app.buttons["backup.export.expense"].exists)
        XCTAssertTrue(app.buttons["backup.export.workouts"].exists)
        XCTAssertTrue(app.buttons["backup.export.feedback"].exists)
    }

    /// Prompt 267: automatic backup is OFF until chosen; choosing a destination backs up and says
    /// so; the backup then appears under "Restore from a cloud backup…" and restores after a
    /// confirmation. Runs against a local test vault (`-uiTestCloudVault`) — the simulator under
    /// test has no iCloud account; the real iCloud transfer is device-owed.
    func testAutomaticBackupIsOptInBacksUpAndRestores() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestSeedFestivalNight", "-uiTestCloudVault", "-uiTestCloudVaultReset"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        let destination = app.descendants(matching: .any)["cloudBackup.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["cloudBackup.now"].exists, "off: no backup controls, nothing uploads")
        XCTAssertFalse(app.switches["cloudBackup.includeHeartRate"].exists)

        destination.tap()
        app.buttons["iCloud"].tap()
        XCTAssertTrue(app.staticTexts["Last backup"].waitForExistence(timeout: 10), "choosing a destination backs up")
        let heartRate = app.switches["cloudBackup.includeHeartRate"]
        XCTAssertTrue(heartRate.exists)
        XCTAssertEqual(heartRate.value as? String, "0", "heart-rate samples are left out unless switched on")
        XCTAssertEqual(app.switches["cloudBackup.wifiOnly"].value as? String, "1")

        app.buttons["cloudBackup.restoreList"].tap()
        let row = app.buttons["cloudBackup.restore.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the backup is listed")
        row.tap()
        let confirm = app.buttons["cloudBackup.restore.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "restore asks before replacing everything")
        confirm.firstMatch.tap()
        let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Restored '")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
    }

    /// The form is lazy: rows below the fold aren't in the tree until scrolled to.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.exists, swipes < 5 { app.swipeUp(); swipes += 1 }
    }
}
