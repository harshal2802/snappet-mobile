import XCTest

/// Instagram-style Clips posts (prompt 196): stats line, caption + suggested #tag, caption search, "View all".
/// Seeded by `-uiTestSeedActivityClips` (Push Day sessions with bench clips on four of them).
@MainActor final class ClipsPostUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["clips", "-uiTestSeedActivityClips"]
        app.launch()
        app.tabBars.buttons["Clips"].tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Scroll the feed until `element` is on screen.
    private func reveal(_ element: XCUIElement) -> Bool {
        let feed = app.scrollViews["clips.feed"]
        for _ in 0..<12 {
            if element.exists, element.isHittable { return true }
            feed.swipeUp()
        }
        return element.exists && element.isHittable
    }

    func testAPostWithStatsCaptionAndViewAll() {
        // A bench post: its stats line and "View all N Barbell Bench Press clips".
        let viewAll = app.buttons.matching(identifier: "clips.post.viewAll").firstMatch
        XCTAssertTrue(viewAll.waitForExistence(timeout: 10) || reveal(viewAll), "a post with more clips of its activity")
        XCTAssertTrue(reveal(viewAll))
        XCTAssertTrue(viewAll.label.contains("View all 4"), viewAll.label)
        let stats = app.staticTexts.matching(identifier: "clips.post.stats").firstMatch
        XCTAssertTrue(stats.exists, "the stats line")
        XCTAssertTrue(stats.label.contains("×"), stats.label)
        snap("01-post")

        // ✎ caption → write + a suggested tag → save.
        let captionButtons = app.buttons.matching(identifier: "clips.post.caption")
        let edit = captionButtons.element(boundBy: 0)
        XCTAssertTrue(edit.waitForExistence(timeout: 4))
        // The ✎ that belongs to the visible post: the one nearest the View-all link.
        let target = (0..<captionButtons.count).map { captionButtons.element(boundBy: $0) }
            .filter { $0.isHittable }
            .min { abs($0.frame.midY - viewAll.frame.midY) < abs($1.frame.midY - viewAll.frame.midY) } ?? edit
        target.tap()
        let field = app.textFields["clips.caption.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("Last rep was a grind ")
        let tag = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'clips.caption.tag.'")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 3), "suggested tags")
        let tagName = tag.label
        tag.tap()
        snap("02-editor")
        app.buttons["clips.caption.save"].tap()

        let caption = app.staticTexts.matching(NSPredicate(format: "identifier == 'clips.post.captionText' AND label CONTAINS 'grind'")).firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "the caption on the post")
        XCTAssertTrue(caption.label.contains(tagName), "with its #tag: \(caption.label)")
        snap("03-captioned")

        // View all → the activity's page.
        XCTAssertTrue(reveal(viewAll))
        viewAll.tap()
        XCTAssertTrue(app.segmentedControls.matching(identifier: "activity.tabs").firstMatch.waitForExistence(timeout: 6),
                      "the Activity page")
        snap("04-activity")
    }

    func testCaptionsAreSearchable() {
        let edits = app.buttons.matching(identifier: "clips.post.caption")
        XCTAssertTrue(edits.firstMatch.waitForExistence(timeout: 10))
        let feed = app.scrollViews["clips.feed"]
        var visible: XCUIElement?
        for _ in 0..<6 {
            visible = (0..<edits.count).map { edits.element(boundBy: $0) }.first { $0.isHittable }
            if visible != nil { break }
            feed.swipeUp()
        }
        XCTAssertNotNil(visible)
        visible?.tap()
        let field = app.textFields["clips.caption.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("zebrafinch")
        app.buttons["clips.caption.save"].tap()

        feed.swipeDown(); feed.swipeDown(); feed.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap()
        search.typeText("zebrafinch")
        let found = app.staticTexts.matching(NSPredicate(format: "identifier == 'clips.post.captionText' AND label CONTAINS 'zebrafinch'")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 5), "search finds the post by its caption")
        XCTAssertEqual(app.buttons.matching(identifier: "clips.post.caption").count, 1, "only that post")
    }
}
