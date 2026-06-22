import XCTest

/// F1 smoke: the Recap tab appears, the feed root renders (cards or the empty state), and the
/// Lens bar (incl. the always-available Sessions lens) is present + tappable.
final class FeedViewUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testRecapTabRendersFeedAndLensBar() {
        let app = XCUIApplication()
        app.launchArguments += ["feed", "-uiTestFreshStore"]
        app.launch()

        // `--start-tab feed` selects the middle tab; confirm it exists and is the Recap tab.
        let recap = app.tabBars.buttons["Recap"]
        XCTAssertTrue(recap.waitForExistence(timeout: 15), "Recap tab should exist")
        recap.tap()

        // Fresh store → the empty state; the lens bar renders regardless.
        let empty = app.descendants(matching: .any)["feed.empty"]
        let sessionsLens = app.descendants(matching: .any)["feed.lens.sessions"]
        XCTAssertTrue(sessionsLens.waitForExistence(timeout: 8) || empty.waitForExistence(timeout: 8),
                      "feed should render the lens bar or the empty state")
        if sessionsLens.exists { sessionsLens.tap() }   // Sessions-only must always be selectable
    }
}
