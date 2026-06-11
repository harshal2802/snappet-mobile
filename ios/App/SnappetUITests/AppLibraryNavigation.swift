import XCTest

/// Shared App Library card lookup for UI tests.
///
/// The grid's `LazyVGrid` only realizes cards near the viewport, and the featured flagship hero
/// (#71) above the grid pushes the Productivity/Finance rows below that realization window — so a
/// below-the-fold card doesn't just sit off-screen, it does not EXIST in the accessibility tree
/// yet. Mirrors the `SuiteSmokeTests` idiom: swipe until the card exists, then until it's
/// hittable (direction-aware, so an overshoot scrolls back).
extension XCUIApplication {
    /// Scroll the App Library until `moduleCard.<id>` exists and is hittable, returning it.
    /// Call with the App Library grid on screen (the Apps tab, at any scroll position).
    /// The caller still asserts existence so the failure message stays local to the test.
    func scrollToModuleCard(_ id: String) -> XCUIElement {
        let card = buttons["moduleCard.\(id)"]
        // Let the grid render before deciding to scroll — the flagship hero sits in the plain
        // (non-lazy) VStack, so it exists at any scroll position once the grid is up.
        _ = buttons["appLibrary.flagship"].waitForExistence(timeout: 6)
        var find = 0
        while !card.exists && find < 12 { swipeUp(); find += 1 }
        var nudge = 0
        while card.exists && !card.isHittable && nudge < 8 {
            // Realized but off-viewport: scroll toward it (back up if a swipe overshot).
            if card.frame.maxY < 1 { swipeDown() } else { swipeUp() }
            nudge += 1
        }
        return card
    }
}
