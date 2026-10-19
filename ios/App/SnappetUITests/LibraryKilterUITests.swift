import XCTest

/// Kilter board climbs in Yours (Library redesign L4c, prompt 188): a board climb shows under Climbing with a KILTER
/// badge, its angle and attempts, opens straight on its climb page, and hides / unhides. Seeded by `-uiTestSeedActivityClips`.
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
        // On a cold-booted simulator the seeded history can land a beat after the Library appears (it opens on
        // Explore until there's history) — wait for Yours before tapping.
        let yours = app.segmentedControls.matching(identifier: "library.mode").firstMatch.buttons["Yours"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: yours)
        await fulfillment(of: [selected], timeout: 10)
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
        // Straight to the climb — never the Kilter module's home first. The simulator has no catalog, so the Library
        // itself explains (on a phone with the catalog the climb's page opens).
        let missing = app.alerts["Climb not in your catalog"]
        XCTAssertTrue(missing.waitForExistence(timeout: 6), "explained in place")
        XCTAssertFalse(app.navigationBars["Kilter Board"].exists, "no detour through the Kilter module")
        snap("02-not-in-catalog")
        missing.buttons["OK"].tap()
    }

    func testHideABoardClimbThenBringItBack() {
        let chip = app.descendants(matching: .any).matching(identifier: "library.chip.climb").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        chip.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'library.yours.row' AND label CONTAINS 'Spicy Pringle'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.swipeLeft()
        app.buttons["Hide"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 4), "hidden")

        let show = app.buttons["library.showHidden"]
        XCTAssertTrue(show.waitForExistence(timeout: 4), "a visible way back")
        XCTAssertTrue(show.label.contains("Show 1 hidden"), show.label)
        snap("03-show-hidden")
        show.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 4), "shown again, dimmed")
        snap("04-hidden-shown")
        row.swipeLeft()
        app.buttons["Unhide"].tap()
        show.tap()   // "Hide hidden" — nothing is hidden any more, so the row stays
        XCTAssertTrue(row.waitForExistence(timeout: 4), "unhidden")
        XCTAssertFalse(app.buttons["library.showHidden"].exists, "nothing left hidden")
    }
}
