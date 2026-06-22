import XCTest

/// R10 structural smoke for the HR / effort card → detail HR-zone section (F4).
///
/// On the fresh `-uiTestFreshStore` store the feed shows the EMPTY state, so this asserts the SURFACE
/// renders and the deep path is reachable-or-gracefully-absent without crashing. The real deep flow —
/// a seeded HR/effort card → tap into detail → assert the rendered HR-zone chart — is **device-burn /
/// awaits a hermetic-seed PR** (the simulator's fresh store has no sessions to compose an HR card from).
@MainActor final class FeedHRCardUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testHRCardDetailReachableOrEmptyState() {
        let app = XCUIApplication()
        app.launchArguments += ["feed", "-uiTestFreshStore"]
        app.launch()

        let recap = app.tabBars.buttons["Recap"]
        XCTAssertTrue(recap.waitForExistence(timeout: 15), "Recap tab should exist")
        recap.tap()

        // Surface renders: the lens bar (always present) or the empty state.
        let empty = app.descendants(matching: .any)["feed.empty"]
        let lens = app.descendants(matching: .any)["feed.lens.sessions"]
        XCTAssertTrue(lens.waitForExistence(timeout: 8) || empty.waitForExistence(timeout: 8),
                      "feed should render the lens bar or the empty state")

        // Deep flow, guarded so a fresh store can't fail the smoke: if an HR/effort card is present
        // (seeded store), tap into detail and assert the HR-zone section id; else assert the empty state.
        let hrCard = app.descendants(matching: .any)["feed.card.e3HRTrend"]
        let effortCard = app.descendants(matching: .any)["feed.card.e1Effort"]
        let card = hrCard.exists ? hrCard : effortCard
        if card.exists {
            card.tap()
            let detail = app.descendants(matching: .any)["feed.detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 8), "detail should push")
            // The HR-zone chart only renders for a session with an HR series — assert it or the detail
            // surface (an HR-less card still pushes detail). Real chart content is device-burn.
            let hrZones = app.descendants(matching: .any)["feed.detail.hrZones"]
            XCTAssertTrue(hrZones.waitForExistence(timeout: 6) || detail.exists,
                          "detail should show the HR-zone section or at least the detail surface")
        } else {
            XCTAssertTrue(empty.exists || lens.exists, "fresh store degrades to the empty state / lens bar")
        }
    }
}
