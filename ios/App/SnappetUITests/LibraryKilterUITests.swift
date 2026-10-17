import XCTest

/// Kilter board climbs in Yours (Library redesign L4c, prompt 188): a board climb shows under Climbing with a KILTER
/// badge, its angle and attempts, and opens in the Kilter module. Seeded by `-uiTestSeedActivityClips`.
@MainActor
final class LibraryKilterUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedActivityClips"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Library"].tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testBoardClimbShowsInYoursAndOpensInKilter() {
        let chip = app.descendants(matching: .any).matching(identifier: "library.chip.climb").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        chip.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'library.yours.row' AND label CONTAINS 'Spicy Pringle'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the board climb is in Yours")
        XCTAssertTrue(row.label.contains("KILTER"), row.label)
        XCTAssertTrue(row.label.contains("40°"), row.label)
        XCTAssertTrue(row.label.contains("12 attempts"), row.label)
        snap("01-kilter-in-yours")

        row.tap()
        // The Kilter module opens on the climb — or, on a device without the catalog (the simulator), says so.
        let missing = app.alerts["Climb not in your catalog"]
        let kilter = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] 'Kilter' OR identifier CONTAINS[c] 'Board'")).firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 8) || kilter.exists, "the Kilter module")
        snap("02-opened-kilter")
    }
}
