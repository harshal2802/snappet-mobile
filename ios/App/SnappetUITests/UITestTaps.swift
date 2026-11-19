import XCTest

/// Waits and taps that hold on a slow simulator (prompt 267). On the CI runner one XCUITest step can take 1–3 s and
/// "wait for the app to idle" up to a minute, so a fixed number of quick queries no longer fits inside the app's own
/// timings. Each helper waits on the condition it needs instead of on time.
extension XCUIApplication {
    /// Taps `button` until `next` exists. A toolbar button tapped while its screen is still sliding in is dropped
    /// (seen on CI: Quick Start tapped, the Gym Tracker home stayed), so tap again while `button` is still there
    /// and `next` hasn't come. Returns whether `next` came; the caller asserts, so the message stays in the test.
    @discardableResult
    func tap(_ button: XCUIElement, until next: XCUIElement, timeout: TimeInterval = 6, tries: Int = 3) -> Bool {
        for _ in 0..<tries {
            if next.exists { return true }
            // `button` gone: the tap took and the next screen is on its way.
            guard button.waitForExistence(timeout: timeout) else { return next.waitForExistence(timeout: timeout) }
            button.tap()
            if next.waitForExistence(timeout: timeout) { return true }
        }
        return next.exists
    }

    /// Quick Start from the Gym Tracker home: the empty session opens (its overall timer shows).
    @discardableResult
    func startQuickSession() -> Bool {
        tap(buttons["workout.quickStart"], until: descendants(matching: .any)["overallWorkoutTimer"], timeout: 8)
    }

    /// Scrolls until `el` exists and is hittable. A `List` only realizes rows near the viewport, so an element
    /// further down does not exist in the accessibility tree yet; how far down depends on what sits above it
    /// (seen on CI: the finished session's recap cards filled the first screen). Direction-aware once it exists,
    /// so an overshoot scrolls back. Returns `el`; the caller asserts.
    @discardableResult
    func scrollIntoView(_ el: XCUIElement, swipes: Int = 8) -> XCUIElement {
        var n = 0
        while !el.waitForExistence(timeout: n == 0 ? 3 : 1) && n < swipes { swipeUp(velocity: .slow); n += 1 }
        n = 0
        while el.exists && !el.isHittable && n < 4 {
            if el.frame.midY < frame.midY { swipeDown(velocity: .slow) } else { swipeUp(velocity: .slow) }
            n += 1
        }
        return el
    }
}
