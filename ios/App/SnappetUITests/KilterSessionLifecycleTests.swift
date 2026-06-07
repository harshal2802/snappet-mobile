import XCTest

/// Regression test for the reported bug: a Kilter board "session" went STALE after starting it and
/// navigating around — the green session bar vanished (the manager was `@State` on a
/// `navigationDestination` view that SwiftUI destroyed on pop). The fix hoists the manager into
/// `AppModel` (survives navigation) + recovers the open session from the store. This drives the
/// manual-session path (no board needed), which is fully sim-testable.
final class KilterSessionLifecycleTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func enterKilter() {
        XCTAssertTrue(app.buttons["moduleCard.kilter"].waitForExistence(timeout: 8),
                      "the Kilter card should be in the App Library")
        app.buttons["moduleCard.kilter"].tap()
        XCTAssertTrue(app.buttons["kilter.more"].waitForExistence(timeout: 8),
                      "the Kilter root (More menu) should appear")
    }

    /// A live session must survive leaving the module and coming back — and stay endable.
    func testSessionSurvivesNavigatingOutAndBack() {
        enterKilter()
        snap("01-kilter-root")

        // Start a manual session from the More menu.
        app.buttons["kilter.more"].tap()
        XCTAssertTrue(app.buttons["Start session"].waitForExistence(timeout: 4))
        app.buttons["Start session"].tap()
        XCTAssertTrue(app.buttons["kilter.session.end"].waitForExistence(timeout: 4),
                      "the session bar should appear after Start")
        snap("02-session-started")

        // Navigate OUT to the App Library, then back IN — the old bug stranded the session here.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["moduleCard.kilter"].waitForExistence(timeout: 6))
        snap("03-back-in-library")
        app.buttons["moduleCard.kilter"].tap()
        XCTAssertTrue(app.buttons["kilter.more"].waitForExistence(timeout: 8))
        snap("04-reentered")

        // THE FIX: the session bar is still there after re-entry (it used to vanish).
        XCTAssertTrue(app.buttons["kilter.session.end"].waitForExistence(timeout: 5),
                      "the session bar must persist after navigating out and back")

        // And the More menu reflects the live session (offers End, not a duplicate Start).
        app.buttons["kilter.more"].tap()
        XCTAssertTrue(app.buttons["End session"].waitForExistence(timeout: 4),
                      "More should offer End after re-entry, not Start (no stale/duplicate session)")
        snap("05-more-shows-end")

        // End it from the menu; the bar goes away.
        app.buttons["End session"].tap()
        XCTAssertFalse(app.buttons["kilter.session.end"].waitForExistence(timeout: 3),
                       "ending the session should remove the bar")
        snap("06-ended")
    }

    /// The summary's "End session" must work even for a session reached after navigation (it closes by
    /// id now, not via the in-memory pointer).
    func testEndFromSummaryWorks() {
        enterKilter()
        app.buttons["kilter.more"].tap()
        XCTAssertTrue(app.buttons["Start session"].waitForExistence(timeout: 4))
        app.buttons["Start session"].tap()
        XCTAssertTrue(app.buttons["kilter.session.open"].waitForExistence(timeout: 4))
        // Open the live summary and end from there.
        app.buttons["kilter.session.open"].tap()
        let endButton = app.buttons["kilter.summary.end"]
        XCTAssertTrue(endButton.waitForExistence(timeout: 5), "the live summary should offer End session")
        snap("07-summary-active")
        endButton.tap()
        // Back on the catalog, the bar is gone.
        if app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 3) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertFalse(app.buttons["kilter.session.end"].waitForExistence(timeout: 3),
                       "ending from the summary should close the session")
        snap("08-ended-from-summary")
    }
}
