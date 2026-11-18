import XCTest

/// The Watch-mode racket player's controls, driven without racing their auto-hide (prompt 267). Shared by the suites
/// that open the player (`RacketPlayerUITests`, `RacketEditUITests`, `RacketVideosUITests`).
///
/// While playing, the controls hide 3 s after the last touch (`RacketPlayerChrome.hideAfter`); paused, they stay. On
/// the CI runner one XCUITest step takes 1–3 s, so "look, read, then tap" can find a control gone at the tap ("no
/// matches"). So a tap comes straight after the controls get a fresh 3 s, and the outcome is checked, not assumed.
@MainActor
struct RacketPlayerControls {
    let app: XCUIApplication

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    var surface: XCUIElement { any("racket.player.surface") }
    /// The play/pause button, whatever it reads.
    var playPause: XCUIElement { app.buttons["racket.player.playPause"] }

    /// The play/pause button only while it reads `label`. A query: asking never fails once the controls have hidden.
    func playPause(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'racket.player.playPause' AND label == %@", label)).firstMatch
    }

    /// Tap the video where nothing else is (upper middle). Shows the controls, or hides them if showing.
    func tapVideo(dx: CGFloat = 0.5) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.33)).tap()
    }

    /// The controls with a fresh 3 s before they hide by themselves: if they show (and may be about to fade), hide
    /// them first, then tap again (apart enough not to be a double tap).
    func freshControls(file: StaticString = #filePath, line: UInt = #line) {
        if playPause.exists {
            tapVideo()
            _ = playPause.waitForNonExistence(timeout: 2)
            Thread.sleep(forTimeInterval: 0.8)
        }
        tapVideo()
        XCTAssertTrue(playPause.waitForExistence(timeout: 3), "the controls show", file: file, line: line)
    }

    /// Taps a control that hides with the others while playing, until `shows` appears. A tap on the video gives the
    /// controls a fresh 3 s (it shows them, or hides them if showing and the next tap shows them); the control is
    /// tapped straight after, the outcome checked and, if they hid first anyway, it goes round. `fresh`: the caller
    /// has just touched the controls (e.g. tapped Play), so the first round taps the control at once if it is there.
    /// (Tapping through the video's coordinates instead was tried: in the landscape walk, whose scene is turned on an
    /// upright simulator, such taps never reach the control, and in portrait they missed it in one local run of four.)
    func tapControl(_ el: XCUIElement, until shows: XCUIElement, fresh: Bool = false,
                    file: StaticString = #filePath, line: UInt = #line) {
        for round in 0..<4 {
            let atOnce = fresh && round == 0    // no extra query before the tap: each one is a CI step
            if !atOnce && shows.exists { break }
            if !(atOnce && el.exists) {
                tapVideo()
                if !el.waitForExistence(timeout: 1) {
                    if shows.exists { break }      // e.g. already paused, the controls were hidden
                    tapVideo()
                    guard el.waitForExistence(timeout: 2) else { continue }
                }
            }
            el.tap()
            if shows.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(shows.exists, "\(shows) after tapping \(el)", file: file, line: line)
    }

    /// Pause (paused, the controls stay and the button reads Play). Playing, the controls may be hidden or about to
    /// hide, so this shows them if needed and taps Pause without racing the auto-hide.
    func pause(file: StaticString = #filePath, line: UInt = #line) {
        tapControl(playPause("Pause"), until: playPause("Play"), file: file, line: line)
        XCTAssertEqual(playPause.label, "Play", file: file, line: line)
    }

    /// Paused with the controls showing: play for a moment and pause again, so the playhead sits just inside where it
    /// was (e.g. a rally's start). The Play tap is a touch, so the controls have a fresh 3 s and Pause goes at once;
    /// on the runner that is about one step (1–2 s), locally well under a second.
    func playAMoment(file: StaticString = #filePath, line: UInt = #line) {
        let play = playPause("Play")
        XCTAssertTrue(play.waitForExistence(timeout: 3), "paused, with the controls showing", file: file, line: line)
        play.tap()
        tapControl(playPause("Pause"), until: playPause("Play"), fresh: true, file: file, line: line)
    }
}
