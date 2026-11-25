import XCTest

/// Prompt 304: the debug "Studio render check" screen (Settings → Developer). Opens it on the
/// simulator, runs the check (without the timed export), and asserts that every scene that is
/// not a placeholder reports pass. The scenes are rendered for real, through the Studio's export and preview, and compared
/// with the golden images the Debug build carries.
final class StudioSelfCheckUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // The seeded history, and the buddy hatched, as `HomeLinksUITests` does: Home then shows
        // the avatar that opens Settings.
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launchOnTestStore()
        app.tabBars.buttons["Home"].tap()
        let hatch = app.buttons["buddy.hatch"]
        XCTAssertTrue(hatch.waitForExistence(timeout: 8))
        hatch.tap()
        XCTAssertTrue(app.buttons["buddy.open"].waitForExistence(timeout: 10))
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func testEverySceneThatIsRenderedPasses() throws {
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let entry = app.buttons["settings.studioSelfCheck"]
        XCTAssertTrue(entry.waitForExistence(timeout: 6), "Settings has a Developer section in a Debug build")
        entry.tap()

        let run = app.buttons["studioSelfCheck.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 6))
        let status = any("studioSelfCheck.status")
        XCTAssertEqual(status.value as? String, "idle")
        // The 20 s export at 1080×1920 is for a phone (about three minutes on a simulator, and
        // the time means nothing there): switch it off. Its code runs in a unit test.
        let timed = app.switches["studioSelfCheck.timedToggle"]
        XCTAssertEqual(timed.value as? String, "1")
        timed.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(timed.value as? String, "0")
        snap("01-before")
        run.tap()

        // Fifteen small scenes, each through the export and the preview.
        let finished = NSPredicate(format: "value == 'pass' OR value == 'fail'")
        let done = expectation(for: finished, evaluatedWith: status)
        wait(for: [done], timeout: 180)
        snap("02-after")

        // One element carries every scene's result: `cut=pass;…;text=skipped;…`.
        let words = try XCTUnwrap(any("studioSelfCheck.results").value as? String)
        var results: [String: String] = [:]
        for pair in words.split(separator: ";") {
            let parts = pair.split(separator: "=")
            if parts.count == 2 { results[String(parts[0])] = String(parts[1]) }
        }
        let rendered = results.filter { $0.value != "skipped" }
        XCTAssertGreaterThanOrEqual(rendered.count, 15, "the scenes the compositor draws today: \(words)")
        for (id, word) in rendered.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(word, "pass", "scene \(id): \(status.label)")
        }
        for id in ["cut", "trim-speed", "filters", "transition-dissolve", "pip", "rotated", "combined"] {
            XCTAssertEqual(results[id], "pass", "scene \(id) is in the list")
        }
        XCTAssertEqual(results["text"], "skipped")
        XCTAssertEqual(results["hr-tile"], "skipped")
        XCTAssertEqual(status.value as? String, "pass", status.label)

        // A scene opens its frames: the golden image, the rendered one and the difference.
        // (Before any scrolling: Settings is a sheet, and a swipe down at the top of it closes it.)
        let cut = any("studioSelfCheck.scene.cut")
        for _ in 0 ..< 3 where !cut.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertEqual(cut.value as? String, "pass")
        cut.tap()
        let frame = any("studioSelfCheck.frame.export-10")
        XCTAssertTrue(frame.waitForExistence(timeout: 6))
        XCTAssertEqual(frame.value as? String, "pass")
        snap("03-scene-frames")
        app.navigationBars.buttons.firstMatch.tap()

        let copy = app.buttons["studioSelfCheck.copy"]
        XCTAssertTrue(run.waitForExistence(timeout: 6) || copy.waitForExistence(timeout: 2))
        for _ in 0 ..< 8 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(any("studioSelfCheck.timing").label.contains("Switched off"), "the timed export was not run")
        XCTAssertTrue(copy.isEnabled)
        snap("04-bottom")
        copy.tap()
        XCTAssertTrue(app.buttons["studioSelfCheck.copy"].label.contains("Copied"))
    }
}
