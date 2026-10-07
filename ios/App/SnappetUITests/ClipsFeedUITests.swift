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

    /// Scroll the feed until `element` exists — posts below the fold aren't created by the lazy stack yet
    /// (the session headers of prompt 167 pushed the seeded festival post below it).
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        for _ in 0..<5 {
            app.scrollViews["clips.feed"].swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
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
        XCTAssertTrue(reveal(title, in: app), "the tagged clip posts as artist · stage")
        let feed = app.scrollViews["clips.feed"]
        feed.swipeDown(); feed.swipeDown()                        // back to the chips

        // The 🎪 chip narrows the feed to festival posts: the dance session's untagged
        // session-clips post disappears, the set post stays. (Counted by post menus — the session's
        // name is also its header now, prompt 167, so the text alone can't tell the post is gone.)
        let chip = app.buttons["clips.filter.festival"]
        XCTAssertTrue(chip.waitForExistence(timeout: 6), "the one new festival chip exists")
        let menus = app.buttons.matching(identifier: "clips.post.menu")
        XCTAssertTrue(app.staticTexts["Snappet Test Festival"].waitForExistence(timeout: 6),
                      "the untagged clips still post under the session title")
        // The chip strip scrolls horizontally; the festival chip sits past the fold on a phone once the
        // Sends chip joined it (prompt 161) — swipe the strip like a person would.
        let strip = app.scrollViews["clips.filter.chips"]
        // (Frame check, not `isHittable` — that throws for an element outside the screen.)
        let screen = app.windows.firstMatch.frame
        for _ in 0..<3 where !screen.contains(chip.frame) { strip.swipeLeft() }
        chip.tap()
        let onePost = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: menus)
        XCTAssertEqual(XCTWaiter().wait(for: [onePost], timeout: 6), .completed,
                       "the festival chip hides non-festival posts")
        XCTAssertTrue(reveal(title, in: app, timeout: 2), "…and keeps the artist · stage post")

        // Tapping the active chip clears it — everything returns.
        feed.swipeDown(); feed.swipeDown()
        chip.tap()
        // (Not a post count: the second post is below the fold, where the lazy stack hasn't built it.)
        let results = app.descendants(matching: .any)["clips.filter.results"]
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: results)
        XCTAssertEqual(XCTWaiter().wait(for: [cleared], timeout: 6), .completed, "the filter is off again")
        XCTAssertFalse(chip.isSelected)
    }

    /// Prompt 163: the ✎ Overlay style sheet opens from the toolbar, a change saves on Done, and it's
    /// still there when the sheet reopens (persisted, not view state).
    func testOverlayStyleSheetSavesTheDefault() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestSeedFestivalNight"]
        app.launch()
        app.tabBars.buttons["Clips"].tap()

        let button = app.buttons["clips.style.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the ✎ Overlay style button is in the toolbar")
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["clips.style.preview"].waitForExistence(timeout: 6))

        app.segmentedControls["clips.style.tabs"].buttons["Title"].tap()
        let show = app.switches["clips.style.showTitle"]
        XCTAssertTrue(show.waitForExistence(timeout: 4))
        XCTAssertEqual(show.value as? String, "1")
        show.switches.firstMatch.tap()
        XCTAssertEqual(show.value as? String, "0")
        app.buttons["clips.style.done"].tap()

        XCTAssertTrue(button.waitForExistence(timeout: 6))
        button.tap()
        app.segmentedControls["clips.style.tabs"].buttons["Title"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 4))
        XCTAssertEqual(show.value as? String, "0", "the saved default survives reopening the sheet")
    }

    /// Prompt 164: hide a clip from the ⋯ menu → it leaves the feed with an Undo toast → the Hidden chip
    /// finds it → Unhide brings it back.
    func testHideFromClipsAndUnhide() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestSeedFestivalNight"]
        app.launch()
        app.tabBars.buttons["Clips"].tap()

        let post = app.staticTexts["Neon Harbor · Pyramid Stage"]
        XCTAssertTrue(reveal(post, in: app))
        app.scrollViews["clips.feed"].swipeDown(); app.scrollViews["clips.feed"].swipeDown()   // back to the top
        // The artist·stage post is the festival-tagged one; open ITS ⋯ menu (the first card's).
        let menus = app.buttons.matching(identifier: "clips.post.menu")
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 6))
        menus.firstMatch.tap()
        let hide = app.buttons["clips.post.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 4))
        hide.tap()

        XCTAssertTrue(app.descendants(matching: .any)["clips.hide.toast"].waitForExistence(timeout: 4),
                      "hiding shows the Undo toast")
        let chip = app.buttons["clips.filter.hidden"]
        XCTAssertTrue(chip.waitForExistence(timeout: 6), "the Hidden chip appears once something is hidden")

        let strip = app.scrollViews["clips.filter.chips"]
        let screen = app.windows.firstMatch.frame
        for _ in 0..<4 where !screen.contains(chip.frame) { strip.swipeLeft() }
        chip.tap()
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: 6), "the hidden clip shows behind the chip")
        menus.firstMatch.tap()
        let unhide = app.buttons["clips.post.unhide"]
        XCTAssertTrue(unhide.waitForExistence(timeout: 4))
        unhide.tap()
        // Nothing hidden any more → the chip goes away once the filter is off.
        chip.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: chip)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 6), .completed)
    }

    /// Prompt 166: the autoplay control is labelled and confirms what it did.
    func testAutoplayControlIsLabelledAndConfirms() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestSeedFestivalNight"]
        app.launch()
        app.tabBars.buttons["Clips"].tap()
        let toggle = app.buttons["clips.autoplay.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "Off")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "On")
        XCTAssertTrue(app.descendants(matching: .any)["clips.toast"].waitForExistence(timeout: 3),
                      "the toggle confirms what changed")
        toggle.tap()   // leave it off for the other tests' shared defaults
    }

    /// Prompt 167: posts sit under a session header, and the grid groups covers by month.
    func testSessionHeadersAndGridMonths() {
        let app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestSeedFestivalNight"]
        app.launch()
        app.tabBars.buttons["Clips"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["clips.session.header"].firstMatch.waitForExistence(timeout: 15),
                      "the seeded session's posts sit under a session header")
        app.buttons["clips.grid.button"].tap()
        XCTAssertTrue(app.staticTexts["clips.grid.month"].firstMatch.waitForExistence(timeout: 6),
                      "the grid groups covers under a month header")
    }
}
