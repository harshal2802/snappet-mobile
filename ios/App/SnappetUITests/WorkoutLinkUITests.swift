import XCTest

/// `snappet://` workout links (prompt 199) — what another app, an NFC tag or a Shortcuts "Open URL" sends:
/// `snappet://quick?activity=…` starts a Quick Session on that activity; `snappet://log?…` logs a set into it;
/// `snappet://finish` finishes it. Seeded by `-uiTestSeedRoutineHistory` (bench press history).
@MainActor final class WorkoutLinkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// `XCUIDevice.shared.system.open`, not `app.open` — the latter relaunches the app (a fresh in-memory store),
    /// where a real link reaches the RUNNING app.
    func testQuickLogAndFinishLinks() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        XCUIDevice.shared.system.open(URL(string: "snappet://quick?activity=Bench")!)
        let name = any("freeform.entityName")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "a Quick Session opened")
        XCTAssertTrue(name.label.contains("Bench"), name.label)
        snap("01-quick")

        XCUIDevice.shared.system.open(URL(string: "snappet://log?activity=Bench&reps=5&weight=82.5")!)
        let row = app.staticTexts.matching(NSPredicate(format: "identifier == 'freeform.setRow' AND label == '5 × 82.5 kg'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the linked set is logged on the running session")
        snap("02-logged")

        XCUIDevice.shared.system.open(URL(string: "snappet://finish")!)
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 10), "the session finished")
        XCTAssertFalse(name.exists)
        snap("03-finished")
    }
}
