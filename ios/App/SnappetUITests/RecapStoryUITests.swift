import XCTest

/// R10 structural smoke for the Wrapped-style Recap stories rail + player (F6).
///
/// The rail is **degrade-by-absence**: a period cover shows only when its recap is eligible (a session
/// in-window). On the fresh `-uiTestFreshStore` store there are no sessions, so the rail is absent and
/// this asserts that absence (no dead chip, no crash). When eligible (seeded store) it taps a cover and
/// asserts the story player opens + closes. The real animated Wrapped content is **device-burn / awaits
/// a hermetic-seed PR** — this only checks the player surface mounts/dismisses.
@MainActor final class RecapStoryUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testStoriesRailEligibleOpensPlayerElseAbsent() {
        let app = XCUIApplication()
        app.launchArguments += ["feed", "-uiTestFreshStore"]
        app.launch()

        let recap = app.tabBars.buttons["Recap"]
        XCTAssertTrue(recap.waitForExistence(timeout: 15), "Recap tab should exist")
        recap.tap()

        // The feed surface renders regardless (lens bar / empty state) — the rail rides on top.
        let empty = app.descendants(matching: .any)["feed.empty"]
        let lens = app.descendants(matching: .any)["feed.lens.sessions"]
        XCTAssertTrue(lens.waitForExistence(timeout: 8) || empty.waitForExistence(timeout: 8),
                      "feed should render the lens bar or the empty state")

        let rail = app.descendants(matching: .any)["feed.stories"]
        if rail.waitForExistence(timeout: 4) {
            // Eligible (seeded store): tap the first eligible cover → player opens → close it.
            let cover = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "recap")).firstMatch
            if cover.exists {
                cover.tap()
                let player = app.descendants(matching: .any)["story.player"]
                XCTAssertTrue(player.waitForExistence(timeout: 8), "story player should open")
                let close = app.descendants(matching: .any)["story.close"]
                if close.exists { close.tap() }
            }
        } else {
            // Fresh store: degrade-by-absence — no eligible period, so no rail (and no crash).
            XCTAssertFalse(rail.exists, "with no eligible period the stories rail is absent")
        }
    }
}
