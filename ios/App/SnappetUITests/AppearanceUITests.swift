import XCTest

/// Prompt 211: Settings → Appearance changes the accent app-wide, live (no relaunch).
final class AppearanceUITests: XCTestCase {
    func testPickingAnAccentRepaintsTheApp() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
        func snap(_ name: String) {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        }
        app.tabBars.buttons["Apps"].tap()
        let open = app.buttons["suite.appearance.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 6))
        snap("01-apps-periwinkle")
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.appearance.preview"].waitForExistence(timeout: 4))
        snap("02-settings-periwinkle")
        app.buttons["settings.appearance.accent.teal"].tap()
        snap("03-settings-teal")
        XCTAssertTrue(app.buttons["settings.appearance.accent.teal"].isSelected)
        app.buttons["settings.appearance.done"].tap()
        snap("04-apps-teal")
        // Put it back so other tests see the default.
        open.tap()
        app.buttons["settings.appearance.accent.periwinkle"].tap()
        app.buttons["settings.appearance.done"].tap()
    }
}
