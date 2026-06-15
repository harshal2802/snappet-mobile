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

        // Start a manual session from the first-class idle-bar control (#75 — Start no longer
        // hides in the More menu).
        XCTAssertTrue(app.buttons["kilter.session.start"].waitForExistence(timeout: 4),
                      "the idle bar should offer a visible Start session control")
        app.buttons["kilter.session.start"].tap()
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

        // THE FIX: the session bar is still there after re-entry (it used to vanish) — and the
        // idle Start control is NOT (no stale/duplicate session on offer).
        XCTAssertTrue(app.buttons["kilter.session.end"].waitForExistence(timeout: 5),
                      "the session bar must persist after navigating out and back")
        XCTAssertFalse(app.buttons["kilter.session.start"].exists,
                       "the live bar owns the slot — no duplicate Start after re-entry")
        snap("05-live-bar-after-reentry")

        // End it from the bar; the idle Start control takes the slot back.
        app.buttons["kilter.session.end"].tap()
        XCTAssertTrue(app.buttons["kilter.session.start"].waitForExistence(timeout: 4),
                      "ending the session should swap the live bar back to the idle Start control")
        snap("06-ended")
    }

    /// The summary's "End session" must work even for a session reached after navigation (it closes by
    /// id now, not via the in-memory pointer).
    func testEndFromSummaryWorks() {
        enterKilter()
        XCTAssertTrue(app.buttons["kilter.session.start"].waitForExistence(timeout: 4))
        app.buttons["kilter.session.start"].tap()
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
