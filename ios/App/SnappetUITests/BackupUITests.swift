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
        app.launch()

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
        XCTAssertFalse(app.buttons["backup.export.journal"].isEnabled)
        XCTAssertFalse(app.buttons["backup.export.feedback"].isEnabled)
        XCTAssertTrue(app.buttons["backup.restore"].isEnabled)
        app.buttons["backup.done"].tap()

        // Reset asks before destroying anything.
        app.buttons["store.health.reset"].tap()
        XCTAssertTrue(app.buttons["store.health.confirmReset"].waitForExistence(timeout: 6))
    }

    func testBackupSheetOpensFromTheAppLibraryToolbar() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()

        let open = app.buttons["suite.backup.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()

        XCTAssertTrue(app.buttons["backup.export"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["backup.restore"].exists)
        XCTAssertTrue(app.buttons["backup.export.journal"].exists)
        XCTAssertTrue(app.buttons["backup.export.budget"].exists)
        XCTAssertTrue(app.buttons["backup.export.expense"].exists)
        XCTAssertTrue(app.buttons["backup.export.workouts"].exists)
        XCTAssertTrue(app.buttons["backup.export.feedback"].exists)
    }
}
