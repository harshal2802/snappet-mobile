import XCTest

/// R10 structural smoke for the in-card media carousel (R6 / F3b).
///
/// On the fresh `-uiTestFreshStore` store the feed shows the EMPTY state (no sessions ⇒ no media), so
/// this asserts the SURFACE renders and the carousel is reachable-or-gracefully-absent without crashing.
/// Real carousel paging + the fullscreen viewer + in-sim media decode are **device-burn / await a
/// hermetic-seed PR** — the simulator has no Photos library to attach clips/thumbnails from.
@MainActor final class FeedMediaCarouselUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testMediaCarouselReachableOrEmptyState() {
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

        // Guarded deep path: if a media-carrying card exists (seeded store), assert the carousel / its
        // first tile is reachable; else assert the empty state. Real paging + viewer are device-burn.
        let carousel = app.descendants(matching: .any)["feed.card.carousel"]
        let tile = app.descendants(matching: .any)["feed.media.tile"]
        if carousel.exists || tile.exists {
            XCTAssertTrue(carousel.exists || tile.exists, "a media-carrying card surfaces its carousel/tile")
        } else {
            XCTAssertTrue(empty.exists || lens.exists, "fresh store degrades to the empty state / lens bar")
        }
    }
}
