import XCTest

/// The Library's ＋ (Library redesign L4a, prompt 186): create a run route / a climb before you've logged it.
@MainActor
final class LibraryCreateUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Library"].tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func openNew(_ id: String) {
        let menu = app.buttons.matching(identifier: "library.new").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 6))
        menu.tap()
        let item = app.buttons.matching(identifier: id).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    func testCreateARunRoute() {
        openNew("library.new.run")
        let name = app.textFields.matching(identifier: "library.new.name").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        name.tap(); name.typeText("Riverside 5k")
        let dist = app.textFields.matching(identifier: "library.new.distance").firstMatch
        dist.tap(); dist.typeText("5")
        app.buttons.matching(identifier: "library.new.save").firstMatch.tap()

        XCTAssertTrue(app.navigationBars["Riverside 5k"].waitForExistence(timeout: 6), "its page opens")
        XCTAssertTrue(app.staticTexts["Not done yet — Log it now when you start it."].waitForExistence(timeout: 3))
        snap("01-route-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier == 'library.yours.row' AND label CONTAINS 'Riverside 5k'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "in Yours")
        XCTAssertTrue(row.label.contains("not done yet"), row.label)
        snap("02-route-in-yours")
    }

    func testCreateAClimbToProject() {
        openNew("library.new.climb")
        let name = app.textFields.matching(identifier: "addClimb.name").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        name.tap(); name.typeText("Red roof")
        app.buttons["Add climb"].tap()
        XCTAssertTrue(app.navigationBars["Red roof"].waitForExistence(timeout: 6), "its page opens")
        snap("03-climb-page")
    }
}
