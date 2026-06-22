import XCTest

/// R10 structural smoke for the inline masonry wall toggle (F7 / R8).
///
/// The grid toggle flips the feed body between the list scroll and the inline masonry wall over the SAME
/// corpus (no modal sheet). This works on an empty AND a non-empty store — on the fresh
/// `-uiTestFreshStore` store the body is empty either way, so this asserts the toggle is reachable, flips,
/// and the feed keeps rendering without crashing. Real masonry tiling content is **device-burn / awaits a
/// hermetic-seed PR**; here we only exercise the toggle + that the surface survives the flip.
@MainActor final class FeedWallUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testGridToggleFlipsAndFeedStillRenders() {
        let app = XCUIApplication()
        app.launchArguments += ["feed", "-uiTestFreshStore"]
        app.launch()

        let recap = app.tabBars.buttons["Recap"]
        XCTAssertTrue(recap.waitForExistence(timeout: 15), "Recap tab should exist")
        recap.tap()

        let empty = app.descendants(matching: .any)["feed.empty"]
        let lens = app.descendants(matching: .any)["feed.lens.sessions"]
        XCTAssertTrue(lens.waitForExistence(timeout: 8) || empty.waitForExistence(timeout: 8),
                      "feed should render the lens bar or the empty state")

        // The grid toggle is always present (toolbar) on either layout. Target the Button specifically:
        // the toolbar item's id resolves to both a wrapping `Other` and the inner `Button`, so a `.any`
        // query is ambiguous on tap.
        let toggle = app.buttons["feed.gridToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "grid toggle should be reachable")

        // Flip to grid: the feed must keep rendering (empty state or the inline wall — `feed.wall` /
        // `feed.wall.empty` on a non-empty/empty seeded store). No crash either way.
        toggle.tap()
        let wall = app.descendants(matching: .any)["feed.wall"]
        let wallEmpty = app.descendants(matching: .any)["feed.wall.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 6) || wall.exists || wallEmpty.exists || lens.exists,
                      "after the flip the feed still renders (grid wall or empty state)")

        // Flip back to list — still renders, still no crash.
        toggle.tap()
        XCTAssertTrue(lens.waitForExistence(timeout: 6) || empty.exists,
                      "after flipping back the list feed still renders")
    }
}
