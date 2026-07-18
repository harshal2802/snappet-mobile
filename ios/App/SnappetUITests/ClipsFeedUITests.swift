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

    /// Highlights P5: the contextual "Connect Apple Health" offer shows on a fresh store (no
    /// watch-imported sessions; the flag is cleared by the fresh-store launch path, so this is
    /// deterministic) and ✕ dismisses it. Connect is deliberately NOT tapped — it pops the real
    /// Health system sheet; the request firing only from that tap is the whole design.
    func testHealthOfferShowsOnFreshStoreAndDismisses() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestFreshStore"]
        app.launch()

        let card = app.descendants(matching: .any)["clips.healthOffer"]
        XCTAssertTrue(card.waitForExistence(timeout: 15),
                      "fresh store → no watch imports + flag cleared → the offer card shows")
        app.descendants(matching: .any)["clips.healthOffer.dismiss"].firstMatch.tap()

        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        wait(for: [gone], timeout: 5)

        // Dismissing the card must not have taken the empty state with it.
        XCTAssertTrue(app.descendants(matching: .any)["clips.empty"].waitForExistence(timeout: 5),
                      "the feed's empty state stays after dismissing the offer")
    }

    /// Festival prompt 03: the seeded night's auto-tagged clip surfaces in Clips as an
    /// artist·stage post behind the ONE new 🎪 Festival chip. (Poster pixels need real Photos
    /// assets — device-owed; the post card + chip behavior are what the simulator can prove.)
    func testFestivalPostAndChipFromASeededNight() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestSeedFestivalNight"]
        app.launch()
        app.tabBars.buttons["Clips"].tap()

        // The tagged clip composes into an artist · stage post (search would match "Neon" free).
        let title = app.staticTexts["Neon Harbor · Pyramid Stage"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the tagged clip posts as artist · stage")

        // The 🎪 chip narrows the feed to festival posts: the dance session's untagged
        // session-clips post disappears, the set post stays.
        let chip = app.buttons["clips.filter.festival"]
        XCTAssertTrue(chip.waitForExistence(timeout: 6), "the one new festival chip exists")
        let sessionPost = app.staticTexts["Snappet Test Festival"]
        XCTAssertTrue(sessionPost.waitForExistence(timeout: 6),
                      "the untagged clips still post under the session title")
        chip.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: sessionPost)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 6), .completed,
                       "the festival chip hides non-festival posts")
        XCTAssertTrue(title.exists, "…and keeps the artist · stage post")

        // Tapping the active chip clears it — everything returns.
        chip.tap()
        XCTAssertTrue(sessionPost.waitForExistence(timeout: 6))
    }
}
