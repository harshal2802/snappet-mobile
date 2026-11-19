import XCTest

/// The Watch-mode racket player's controls (prompt 267). Shared by the suites that drive them (`RacketPlayerUITests`,
/// `RacketEditUITests`, `RacketVideosUITests`).
///
/// While playing, the controls hide 3 s after the last touch (`RacketPlayerChrome.hideAfter`); paused, they stay. On the
/// CI runner one XCUITest tap step takes 3–4 s (find, interrupting elements, synthesize, wait for idle), longer than the
/// timer, so no order of test steps can tap a control reliably while playing. So these suites launch with
/// `hideAfterArguments` (a long delay, UI-test store only), and the helpers are plain show-then-tap with the outcome
/// checked. The auto-hide itself, with the real 3 s, is `RacketPlayerUITests.testControlsHideByThemselvesWhilePlaying`,
/// which launches without the override.
@MainActor
struct RacketPlayerControls {
    let app: XCUIApplication

    /// Launch arguments that hold the controls for 60 s after the last touch instead of 3 (the app honours them only on
    /// the UI-test store: `RacketPlayerChrome.hideAfter(arguments:)`).
    nonisolated static let hideAfterArguments = ["-uiTestPlayerControlsHideAfter", "60"]

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    var surface: XCUIElement { any("racket.player.surface") }
    /// The play/pause button, whatever it reads.
    var playPause: XCUIElement { app.buttons["racket.player.playPause"] }

    /// The play/pause button only while it reads `label`.
    func playPause(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'racket.player.playPause' AND label == %@", label)).firstMatch
    }

    /// Tap the video where nothing else is (upper middle). Shows the controls, or hides them if showing.
    func tapVideo(dx: CGFloat = 0.5) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.33)).tap()
    }

    /// The controls showing: a tap on the video if they are hidden.
    func showControls(file: StaticString = #filePath, line: UInt = #line) {
        if !playPause.exists { tapVideo() }
        XCTAssertTrue(playPause.waitForExistence(timeout: 3), "the controls show", file: file, line: line)
    }

    /// Show the controls, tap `el` (one of them), and check that `shows` appears.
    func tapControl(_ el: XCUIElement, until shows: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        showControls(file: file, line: line)
        XCTAssertTrue(el.waitForExistence(timeout: 3), "\(el) with the controls", file: file, line: line)
        el.tap()
        XCTAssertTrue(shows.waitForExistence(timeout: 3), "\(shows) after tapping \(el)", file: file, line: line)
    }

    /// Paused, with the controls showing (the button reads Play). Taps Pause only if playing.
    func pause(file: StaticString = #filePath, line: UInt = #line) {
        showControls(file: file, line: line)
        if !playPause("Play").exists {
            tapControl(playPause("Pause"), until: playPause("Play"), file: file, line: line)
        }
        XCTAssertEqual(playPause.label, "Play", file: file, line: line)
    }

    /// A double tap on the video's left half: 10 s back (`RacketPlayerTaps`). The pair toggles the controls twice, so
    /// they end as they were, and it neither plays nor pauses. If the app reads the two taps more than 0.3 s apart (a
    /// busy main thread), they are two single taps: the controls toggle twice and the playhead stays; callers check.
    func doubleTapBack() {
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.33)).doubleTap()
    }
}
