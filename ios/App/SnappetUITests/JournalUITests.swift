import XCTest

/// UI flow for the Journal mini-app's tags + search feature: open Journal from the App Library,
/// create two entries (one carrying a unique tag), then search by that tag and assert the list
/// filters down to the tagged entry. Clearing the search restores the full list.
final class JournalUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    /// Wait until `element` is no longer present (the inverse of `waitForExistence`).
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Open the Journal module from the App Library.
    private func openJournal() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.journal"]
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Journal card")
        var tries = 0
        while !card.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        card.tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 6), "Journal should open")
    }

    /// Create one entry with the given title and optional tag.
    private func createEntry(title: String, tag: String?) {
        app.buttons["journal.add"].tap()

        let titleField = app.textFields["journal.titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 4), "editor title field should appear")
        titleField.tap()
        titleField.typeText(title)

        if let tag {
            let tagField = app.textFields["journal.tagField"]
            XCTAssertTrue(tagField.waitForExistence(timeout: 4), "editor tag field should appear")
            tagField.tap()
            // Comma commits the tag into a chip.
            tagField.typeText("\(tag),")
        }

        app.buttons["journal.save"].tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 4), "should return to the list")
    }

    func testTagAndSearchFlow() {
        openJournal()

        // Unique tokens so the assertions are independent of any pre-existing store contents.
        let unique = String(UInt32.random(in: 100_000...999_999))
        let taggedTitle = "Tagged-\(unique)"
        let plainTitle = "Plain-\(unique)"
        let tag = "trip\(unique)"

        createEntry(title: taggedTitle, tag: tag)
        createEntry(title: plainTitle, tag: nil)

        let taggedCell = app.staticTexts[taggedTitle]
        let plainCell = app.staticTexts[plainTitle]
        XCTAssertTrue(taggedCell.waitForExistence(timeout: 4), "tagged entry should be listed")
        XCTAssertTrue(plainCell.waitForExistence(timeout: 4), "plain entry should be listed")

        // Search by the unique tag → only the tagged entry should remain.
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 4), "search field should be present")
        searchField.tap()
        searchField.typeText(tag)

        XCTAssertTrue(taggedCell.waitForExistence(timeout: 4), "tag search should keep the tagged entry")
        // The plain cell is already on screen, so wait for it to *disappear* as the filter applies
        // rather than relying on a still-cached `exists` returning false immediately.
        XCTAssertTrue(waitForDisappearance(of: plainCell, timeout: 4),
                      "tag search should hide the untagged entry")

        // Clear the search → both entries return.
        if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
        else { searchField.buttons.firstMatch.tap() }

        XCTAssertTrue(taggedCell.waitForExistence(timeout: 4), "clearing search should restore the tagged entry")
        XCTAssertTrue(plainCell.waitForExistence(timeout: 4), "clearing search should restore the plain entry")
    }

    /// Prompt 34 (review blocker guard): switching tabs while composing a new entry must
    /// not delete it out from under the editor — the typed entry still saves on Done.
    func testTabSwitchWhileComposingKeepsTheEntry() {
        openJournal()

        app.buttons["journal.add"].tap()
        let titleField = app.textFields["journal.titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 4), "editor should open")

        // Leave for Home mid-compose (the editor stays pushed on the Apps tab's stack)…
        app.tabBars.buttons["Home"].tap()
        app.tabBars.buttons["Apps"].tap()

        // …come back, type the entry, and save it.
        XCTAssertTrue(titleField.waitForExistence(timeout: 4), "editor should still be up")
        titleField.tap()
        titleField.typeText("Survived the tab switch")
        app.buttons["journal.save"].tap()

        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 4), "should return to the list")
        XCTAssertTrue(app.staticTexts["Survived the tab switch"].waitForExistence(timeout: 4),
                      "the entry typed after a tab switch must persist")
    }

    /// Prompt 34: opening the editor with + and leaving via the back button without typing
    /// anything must not persist a blank "Untitled" row.
    func testAbandoningNewEntryLeavesNoBlankRow() {
        openJournal()

        app.buttons["journal.add"].tap()
        let titleField = app.textFields["journal.titleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 4), "editor should open")

        // Leave via the system back button (not Done) — the abandoned-entry path.
        app.navigationBars["New Entry"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Journal"].waitForExistence(timeout: 4), "should return to the list")

        // Fresh store + no content ⇒ the list must be back to its empty state, with no row.
        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 4),
                      "abandoning a blank entry should leave the journal empty")
        XCTAssertFalse(app.buttons["journalRow"].exists, "no Untitled row should persist")
    }
}
