import XCTest

/// Quick Session redesign Phase 3 — the live climbing **stats ribbon** + the expanded **live-stats
/// sheet**. Adds a climb, logs a Sent attempt, asserts the docked ribbon (`freeform.statsRibbon`) reads
/// "1 send", taps it, and asserts the expanded sheet (`freeform.statsExpand`) shows the grade pyramid.
final class LiveClimbStatsTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    /// Open the freeform player from the dashboard's Quick Start.
    private func openFreeformPlayer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 6))
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5), "Quick Start should be on the dashboard")
        quick.tap()
        XCTAssertTrue(app.staticTexts["Quick session"].waitForExistence(timeout: 5)
            || app.navigationBars["Quick session"].waitForExistence(timeout: 2),
            "the freeform player should open")
    }

    /// Add a climb via the "Add a climb" sheet and log one attempt of `outcome` on its inline strip.
    private func addClimbAndLog(grade: String, name: String, outcome: String) {
        // Empty-state Climbing card is the fastest entry; falls back to the add menu if it's gone.
        let card = app.buttons["freeform.cardClimbing"]
        if card.waitForExistence(timeout: 4) {
            card.tap()
        } else {
            app.buttons["freeform.addExercise"].tap()
            app.buttons["Climbing"].tap()
        }
        let rung = app.buttons["addClimb.rung.\(grade)"]
        XCTAssertTrue(rung.waitForExistence(timeout: 6), "the grade rail should offer the \(grade) rung")
        rung.tap()
        typeIn(app.textFields["addClimb.name"], name)
        app.buttons["addClimb.addAndLog"].tap()
        let outcomeButton = app.buttons["freeform.outcome.\(outcome)"]
        XCTAssertTrue(outcomeButton.waitForExistence(timeout: 6),
                      "the new climb card should auto-open its inline outcome strip")
        outcomeButton.tap()
    }

    func testStatsRibbonAndExpandSheet() {
        openFreeformPlayer()

        // Log a Sent V4. The ribbon should appear reading "1 send".
        addClimbAndLog(grade: "V4", name: "Cave", outcome: "sent")

        // The ribbon is docked on the OVERVIEW page (pager, prompt 109) — jump there via the rail.
        let overviewChip = app.buttons["freeform.rail.0"]
        XCTAssertTrue(overviewChip.waitForExistence(timeout: 4), "the rail should offer the overview chip")
        overviewChip.tap()
        let ribbon = app.buttons["freeform.statsRibbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 6),
                      "the live stats ribbon should appear once climbing is logged")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1 send'")).firstMatch
            .waitForExistence(timeout: 4), "the ribbon should read '1 send' after a Sent attempt")

        // Tap the ribbon → the expanded stats sheet with the grade pyramid.
        ribbon.tap()
        XCTAssertTrue(app.otherElements["freeform.statsExpand"].waitForExistence(timeout: 6)
            || app.descendants(matching: .any)["freeform.statsExpand"].waitForExistence(timeout: 2),
            "tapping the ribbon should present the live-stats sheet")
        XCTAssertTrue(app.descendants(matching: .any)["freeform.statsPyramid"].waitForExistence(timeout: 6),
                      "the live-stats sheet should show the grade pyramid")
    }
}
