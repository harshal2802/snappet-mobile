import XCTest

/// Prompt 82 smoke: the **Clips** tab is wired in as the 4th bottom tab (Home · Clips · Recap · Apps),
/// selects via the `clips` launch arg, and its feed root renders — the empty state on a fresh store.
///
/// The carousel pages, the live HR scorebug, the climb/exercise-name overlay, and the ⋯ actions
/// (Edit this clip / Edit all / Go to session) all need real Photos assets + a captured HR series, so
/// they only fully render on a physical device — they're out of scope for the simulator. This verifies
/// the tab wiring + the view + its empty state are reachable, the way `FeedViewUITests` does for Recap.
@MainActor final class ClipsFeedUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testClipsTabSitsBetweenHomeAndRecapAndRendersEmptyState() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestFreshStore"]
        app.launch()

        // The four tabs all exist: Home · Clips · Recap · Apps.
        let home = app.tabBars.buttons["Home"]
        let clips = app.tabBars.buttons["Clips"]
        let recap = app.tabBars.buttons["Recap"]
        XCTAssertTrue(clips.waitForExistence(timeout: 15), "Clips tab should exist")
        XCTAssertTrue(home.exists, "Home tab should exist")
        XCTAssertTrue(recap.exists, "Recap tab should still exist")

        // Order: Clips sits BETWEEN Home and Recap (the acceptance criterion).
        XCTAssertTrue(home.frame.minX < clips.frame.minX && clips.frame.minX < recap.frame.minX,
                      "Clips should sit between Home and Recap")

        // `clips` launch arg selects the tab; tap to be explicit, then assert the empty state renders
        // (fresh store → no media → the "No clips yet" state, not a crash).
        clips.tap()
        let empty = app.descendants(matching: .any)["clips.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 8),
                      "Clips should render its empty state on a fresh store")
    }
}
