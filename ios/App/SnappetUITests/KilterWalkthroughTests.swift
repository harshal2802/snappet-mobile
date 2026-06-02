import XCTest

/// Drives the Kilter Board mini-app end-to-end at a deliberately watchable pace so the simulator
/// screen can be screen-recorded into the walkthrough video embedded in the knowledge graph
/// (mirrors `LiveWorkoutStudioWalkthroughTests`). It exercises the headline surfaces in story order:
/// catalog (search + Climb of the day) → a climb's board render → angle + send logging → the grade
/// chart → the Filters sheet → Settings. Each step pauses so the recording reads as a demo.
///
/// It's resilient: every interaction is guarded, so a missing optional control just skips rather than
/// failing the recording. Run with the simulator being recorded:
///   xcrun simctl io booted recordVideo out.mov &
///   xcodebuild test-without-building -only-testing:SnappetUITests/KilterWalkthroughTests …
final class KilterWalkthroughTests: XCTestCase {

    func testWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore"]
        app.launch()

        // App Library → Kilter Board card.
        app.tabBars.buttons["Apps"].tap()
        sleep(1)
        let card = app.buttons["moduleCard.kilter"]
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "Kilter card should exist")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        sleep(3)   // catalog: search bar, filter chips, Climb of the day, list

        // Open a climb → the board render.
        let row = app.buttons["kilter.climbRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "catalog should list climbs")
        row.tap()
        sleep(3)   // detail: the full board grid + the climb's holds

        // Switch angle (board difficulty is per-angle).
        let anglePicker = app.buttons["kilter.angle"]
        if anglePicker.waitForExistence(timeout: 4) {
            anglePicker.tap()
            sleep(1)
            let anyAngle = app.buttons.matching(NSPredicate(format: "label CONTAINS '°'")).firstMatch
            if anyAngle.waitForExistence(timeout: 2) { anyAngle.tap() }
            sleep(2)
        }

        // Log a send → animated confirmation.
        let send = app.buttons["kilter.log.sent"]
        if send.waitForExistence(timeout: 4) { send.tap(); sleep(2) }

        // Scroll down to the per-angle grade chart, then back up.
        app.swipeUp(); sleep(2)
        app.swipeUp(); sleep(2)
        app.swipeDown(); app.swipeDown(); sleep(1)

        // Back to the catalog.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)

        // Open the Filters sheet, then dismiss.
        let filters = app.buttons["kilter.filtersButton"]
        if filters.waitForExistence(timeout: 4) {
            filters.tap()
            sleep(2)
            let done = app.buttons["kilter.filter.done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
            sleep(1)
        }

        // More menu → Settings.
        let more = app.buttons["kilter.more"]
        if more.waitForExistence(timeout: 4) {
            more.tap()
            sleep(1)
            let settings = app.buttons["Settings"].firstMatch
            if settings.waitForExistence(timeout: 3) { settings.tap() }
            sleep(3)   // settings: defaults, grade scale, clear history
            if app.navigationBars.buttons.element(boundBy: 0).exists {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
        }
        sleep(1)
    }
}
