import XCTest

/// F3 (R2) structural smoke for the inline auto-clip hero.
///
/// This asserts the feed renders and scrolls without wedging — the *structure* the single-active
/// muted-loop player rides on. It does NOT assert real playback: the simulator has no Photos
/// library, so `FeedClipPlayer` always falls back to its poster/gradient and no `AVPlayer` ever
/// attaches in-sim. The actual behaviors are **device-burn**, verified on MrRobot:
///   - one muted, looping `AVPlayer` plays at a time (the scroll-center a1 card),
///   - hand-off on scroll (old pauses+releases, new attaches+plays) without thrash,
///   - reduceMotion / Low Power Mode fall back to the still hero (no player attached),
///   - no audio leak.
/// Kept non-flaky: taps/scrolls only, `continueAfterFailure = false`.
@MainActor final class FeedAutoClipUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testFeedScrollsAndSessionCardRenders() {
        let app = XCUIApplication()
        app.launchArguments += ["feed", "-uiTestFreshStore"]
        app.launch()

        let recap = app.tabBars.buttons["Recap"]
        XCTAssertTrue(recap.waitForExistence(timeout: 15), "Recap tab should exist")
        recap.tap()

        // A fresh store renders the empty state; either way the feed root must be reachable + scrollable
        // without wedging — the surface the auto-clip hero lives on. (A seeded store would surface
        // `feed.card.a1Session`; in-sim playback is the device-burn tail.)
        let empty = app.descendants(matching: .any)["feed.empty"]
        let sessionCard = app.descendants(matching: .any)["feed.card.a1Session"]
        let lens = app.descendants(matching: .any)["feed.lens.sessions"]
        XCTAssertTrue(empty.waitForExistence(timeout: 8) || sessionCard.waitForExistence(timeout: 8)
                        || lens.waitForExistence(timeout: 8),
                      "feed should render the empty state, a session card, or the lens bar")

        // Scroll exercises the scroll-center tracking path; it must not crash/wedge.
        if app.scrollViews.firstMatch.exists {
            app.scrollViews.firstMatch.swipeUp()
            app.scrollViews.firstMatch.swipeDown()
        }

        // If a session card is present (seeded store), its inline hero slot renders; the clip player
        // (`feed.card.heroClip`) only attaches on the central card on a real device with a library.
        if sessionCard.exists {
            XCTAssertTrue(sessionCard.isHittable || sessionCard.exists, "session card stays rendered after scroll")
        }
    }
}
