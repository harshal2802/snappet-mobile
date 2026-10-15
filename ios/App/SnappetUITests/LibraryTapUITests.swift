import XCTest

/// Library rows open wherever you tap them (prompt 182). Under `.buttonStyle(.plain)` only drawn content
/// hit-tested, so a climb / run starter — short title, short subtitle — had a dead middle and right side, and
/// a tap at the row's centre did nothing. Strength rows happened to work because their long subtitles reached
/// the centre.
@MainActor
final class LibraryTapUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Library"].tap()
    }

    private func climbRow(_ title: String) -> XCUIElement {
        // The seeded history makes "Yours" the default tab (prompt 183) — the templates live in Explore.
        app.segmentedControls.matching(identifier: "library.mode").firstMatch.buttons["Explore"].tap()
        let chip = app.descendants(matching: .any).matching(identifier: "library.chip.climb").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        chip.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'exerciseRow' AND label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)   // a tap on a still-decelerating list only stops the scroll
        return row
    }

    func testClimbRowOpensWhenTappedAtItsCentre() {
        climbRow("Top-rope route").tap()
        XCTAssertTrue(app.navigationBars["Top-rope route"].waitForExistence(timeout: 6), "the climb's detail opens")
    }

    func testClimbRowOpensWhenTappedOnItsEmptyRightSide() {
        climbRow("Boulder").coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Boulder"].waitForExistence(timeout: 6), "the empty side of the row is tappable too")
        // …and the climbing progress link added in prompt 181 is now reachable.
        let progress = app.buttons["library.viewProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
        progress.tap()
        XCTAssertTrue(app.navigationBars["Climbing"].waitForExistence(timeout: 6), "the climbing overview")
    }
}
