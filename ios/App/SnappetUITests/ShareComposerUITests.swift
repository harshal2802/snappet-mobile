import XCTest

/// R10 structural smoke for the share composer (F5): card → detail → Share → the composer's Share button.
///
/// On the fresh `-uiTestFreshStore` store the feed shows the EMPTY state (no cards), so this asserts the
/// SURFACE renders and the share path is reachable-or-gracefully-absent without crashing. The real flow —
/// the rendered share card / the "Animate" clip export — is **device-burn / awaits a hermetic-seed PR**
/// (render + AVFoundation export don't run in-sim with no Photos library).
@MainActor final class ShareComposerUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testShareComposerReachableOrEmptyState() {
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

        // Guarded deep path: if any feed card is present (seeded store), open detail → Share → assert
        // the composer's Share button, then dismiss. Else assert the empty state. Animate/render is device-burn.
        let card = app.descendants(matching: .any)["feed.card.a1Session"]
        if card.exists {
            card.tap()
            let detail = app.descendants(matching: .any)["feed.detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 8), "detail should push")
            let share = app.descendants(matching: .any)["feed.share"]
            if share.exists {
                share.tap()
                let shareButton = app.descendants(matching: .any)["share.button"]
                XCTAssertTrue(shareButton.waitForExistence(timeout: 6), "share composer exposes a Share button")
                // Dismiss the sheet without invoking the real (device-burn) share sheet.
                app.swipeDown()
            }
        } else {
            XCTAssertTrue(empty.exists || lens.exists, "fresh store degrades to the empty state / lens bar")
        }
    }
}
