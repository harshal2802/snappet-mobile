import XCTest

/// Smoke test: every mini-app opens from the App Library via its (now Button) card — verifying the
/// shared `SuiteRouter` / `ModuleRoute` entry navigation works for all 9 modules.
final class SuiteSmokeTests: XCTestCase {

    func testEverySuiteAppOpens() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Apps"].tap()

        // "workout" (Workout Reels) retired by the highlights convergence (P3) — reels are now an
        // action on sessions + the weekly cut, not a destination tile.
        let ids = ["workout-log", "kilter", "pomodoro", "habit", "journal", "tip", "expense", "budget"]
        for id in ids {
            let card = app.buttons["moduleCard.\(id)"]
            // The LazyVGrid only realizes cards near the viewport, so scroll until the card exists
            // before asserting — the Finance cards sit well below the fold (more so now that Kilter
            // adds a Fitness row).
            var find = 0
            while !card.exists && find < 12 { app.swipeUp(); find += 1 }
            XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a card for \(id)")

            // Scroll the card into a hittable position if it's below the fold.
            var tries = 0
            while !card.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
            card.tap()

            // Navigated into the module → the back button (to "Apps") appears.
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 6), "module \(id) should open from its card")
            back.tap()
            sleep(1)
            // Return to the top of the grid for the next lookup.
            var up = 0
            while app.buttons["moduleCard.workout"].exists == false && up < 8 { app.swipeDown(); up += 1 }
        }
    }
}
