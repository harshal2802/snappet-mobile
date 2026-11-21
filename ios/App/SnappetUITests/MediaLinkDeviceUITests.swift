import XCTest

/// Prompt 265, device leg: on a REAL Photos library with full access, a clip whose asset is gone says
/// "Not on this phone" once played. The simulator cannot hold Photos access under test, so this is
/// device-only and opt-in — it runs against the phone's real store and is strictly READ-ONLY (it
/// scrolls the Clips feed and plays clips; it never creates, edits or deletes anything).
///
///     TEST_RUNNER_SNAPPET_DEVICE_MEDIA_LINK=1 xcodebuild test -scheme Snappet \
///       -destination 'id=<device udid>' -allowProvisioningUpdates \
///       -only-testing:SnappetUITests/MediaLinkDeviceUITests
@MainActor final class MediaLinkDeviceUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testDeadClipSaysNotOnThisPhoneOnARealLibrary() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs a real Photos library with full access — device only")
        #else
        guard ProcessInfo.processInfo.environment["SNAPPET_DEVICE_MEDIA_LINK"] == "1" else {
            throw XCTSkip("opt-in: runs against the phone's real store (read-only)")
        }
        let app = XCUIApplication()
        app.launchArguments += ["clips"]
        app.launch()
        let tab = app.tabBars.buttons["Clips"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let feed = app.scrollViews["clips.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 30), "the real store has clips")

        // Jump straight to a session known to hold dead clips instead of scrolling the whole feed:
        // pass a search term via SNAPPET_DEVICE_MEDIA_LINK_QUERY (e.g. a session name read off the
        // store). Search only filters the feed — nothing is written.
        if let query = ProcessInfo.processInfo.environment["SNAPPET_DEVICE_MEDIA_LINK_QUERY"], !query.isEmpty {
            let search = app.searchFields.firstMatch
            if !search.waitForExistence(timeout: 3) { feed.swipeDown() }
            XCTAssertTrue(search.waitForExistence(timeout: 5), "Clips search field")
            search.tap()
            search.typeText(query + "\n")
        }

        let missing = app.staticTexts["Not on this phone"]
        let screen = app.windows.firstMatch.frame
        var playedALiveClip = false
        var stops = 0
        while !missing.exists && stops < 12 {
            // Play the first post whose media has a tappable band on screen (a post shows its still
            // poster until played; the placeholder only exists on the mounted surface).
            let pages = app.descendants(matching: .any).matching(identifier: "clips.post.page")
            for index in 0..<min(pages.count, 4) {
                let frame = pages.element(boundBy: index).frame
                let y = max(frame.minY + 60, 220)
                guard frame.width > 0, y < frame.maxY - 20, y < screen.maxY - 160 else { continue }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: y)).tap()
                break
            }
            if missing.waitForExistence(timeout: 3) { break }
            if app.descendants(matching: .any)["feed.media.player"].exists { playedALiveClip = true }
            // A clip that was already playing opens fullscreen on tap — close it and move on.
            if app.descendants(matching: .any)["clips.fullscreen.playpause"].exists { app.swipeDown() }
            feed.swipeUp()
            stops += 1
        }

        XCTAssertTrue(missing.exists, "no dead clip found after \(stops) scrolls")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@", "was removed from Photos")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Couldn’t load this clip"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "not-on-this-phone (after \(stops) scrolls, live clip played: \(playedALiveClip))"
        shot.lifetime = .keepAlways
        add(shot)
        #endif
    }
}
