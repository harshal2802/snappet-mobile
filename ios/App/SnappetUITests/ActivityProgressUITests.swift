import XCTest

/// Activity progress (prompt 178+): every past clip of an activity, from the live pager and the session
/// detail. Seeded by `-uiTestSeedActivityClips` — the routine-history fixture plus bench clips on four
/// past Push Days (and one untagged photo).
@MainActor
final class ActivityProgressUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedActivityClips"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openGymTracker() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
    }

    private func assertSheetShowsFourBenchClips() {
        XCTAssertTrue(any("activity.clips.tile").waitForExistence(timeout: 6), "the past-clips sheet's tiles")
        // The grid is lazy, so assert the sheet's summary line rather than counting rendered tiles.
        let summary = any("activity.clips.summary")
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(summary.label.contains("4 clips") && summary.label.contains("4 sessions"), summary.label)
        XCTAssertTrue(summary.label.contains("1 untagged"), summary.label)
    }

    func testSessionDetailOpensPastClipsAndViewer() {
        openGymTracker()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Push Day'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()

        let chip = any("activity.pastClips")
        for _ in 0..<6 where !chip.isHittable { app.swipeUp() }
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "a past-clips chip on the bench header")
        XCTAssertTrue(chip.label.contains("4 past clips"), chip.label)
        snap("01-detail-chip")
        chip.tap()

        assertSheetShowsFourBenchClips()
        snap("02-sheet")
        any("activity.clips.tile").tap()
        XCTAssertTrue(any("activity.clips.viewer").waitForExistence(timeout: 6), "the fullscreen viewer")
        snap("03-viewer")
        any("activity.clips.close").tap()
        any("activity.clips.done").tap()
    }

    func testLivePagerShowsPastClipsChip() {
        openGymTracker()
        app.segmentedControls.buttons["Routines"].tap()
        let routine = app.staticTexts["Push Day"].firstMatch
        // The seeded routine sits under the starter routines — scroll until it's on screen.
        for _ in 0..<6 where !(routine.exists && routine.isHittable) { app.swipeUp() }
        XCTAssertTrue(routine.waitForExistence(timeout: 6))
        routine.tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        start.tap()

        let chip = any("activity.pastClips")
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "the chip on the bench page")
        XCTAssertTrue(chip.label.contains("4 past clips"), chip.label)
        snap("04-pager-chip")
        chip.tap()
        assertSheetShowsFourBenchClips()
        snap("05-pager-sheet")
    }
}
