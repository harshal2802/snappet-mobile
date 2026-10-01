import XCTest

/// Prompt 146: a session's detail leads with its routine's history — the series ordinal, change since
/// last time, the badges it earned, the progress chart and the next milestone — for each workout type.
/// Seeded by `-uiTestSeedRoutineHistory` (Push Day ×8, Finger day ×6, Bouldering ×5, Easy run ×4).
@MainActor
final class SessionInsightsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openLatest(_ name: String) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "a \(name) history row")
        row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 6), "titled with the routine name")
    }

    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    func testDetailShowsRoutineHistoryForEveryType() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()

        // Strength: 8th Push Day, a bench PR, the trend and per-exercise compares.
        openLatest("Push Day")
        XCTAssertTrue(any("insights.subtitle").waitForExistence(timeout: 4))
        XCTAssertTrue(any("insights.subtitle").label.contains("8th Push Day"), any("insights.subtitle").label)
        // P3: what the session earned, at the top.
        XCTAssertTrue(any("session.xp").exists, "the XP line")
        XCTAssertTrue(any("session.xp").label.hasPrefix("+"), any("session.xp").label)
        XCTAssertTrue(any("insights.badges").exists, "earned badges")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'PR'")).firstMatch.exists)
        XCTAssertTrue(any("insights.progress").exists, "progress chart")
        XCTAssertTrue(any("insights.milestone").exists, "next milestone")
        snap("01-push-top")
        app.swipeUp()
        XCTAssertTrue(any("insights.exercise").exists, "exercise compare cards")
        snap("02-push-exercises")
        back()

        // Hangboard: heaviest load + force grid.
        openLatest("Finger day")
        XCTAssertTrue(any("insights.subtitle").waitForExistence(timeout: 4))
        XCTAssertTrue(any("insights.subtitle").label.contains("6th Finger day"))
        snap("03-finger-top")
        app.swipeUp()
        XCTAssertTrue(any("insights.forceGrid").waitForExistence(timeout: 3), "force per hang")
        snap("04-finger-force")
        back()

        // Climbing: first V5 send + pyramid vs 30 days.
        openLatest("Bouldering")
        XCTAssertTrue(any("insights.subtitle").waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'First V5 send'")).firstMatch.exists)
        snap("05-boulder-top")
        app.swipeUp()
        XCTAssertTrue(any("insights.pyramid").waitForExistence(timeout: 3))
        snap("06-boulder-pyramid")
        back()

        // Running: progress over pace, 4th run.
        openLatest("Easy run")
        XCTAssertTrue(any("insights.subtitle").waitForExistence(timeout: 4))
        XCTAssertTrue(any("insights.subtitle").label.contains("4th Easy run"))
        snap("07-run-top")
    }
}
