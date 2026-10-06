import XCTest

/// Household P2 (prompt 157) end to end on TWO simulators over real Bonjour: one runs the inviter, the
/// other the joiner, coordinating through files in a shared folder. Skipped in normal runs. Run both at
/// once (build-for-testing, then test-without-building per simulator) with
/// `TEST_RUNNER_HOUSEHOLD_E2E_ROLE=inviter|joiner` and `TEST_RUNNER_HOUSEHOLD_E2E_DIR=<folder>`.
final class HouseholdE2ETests: XCTestCase {
    private var role: String? { ProcessInfo.processInfo.environment["HOUSEHOLD_E2E_ROLE"] }
    private var dir: URL? { ProcessInfo.processInfo.environment["HOUSEHOLD_E2E_DIR"].map { URL(fileURLWithPath: $0) } }

    private func waitForFile(_ name: String, timeout: TimeInterval) -> String? {
        guard let url = dir?.appendingPathComponent(name) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty { return s }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func write(_ name: String, _ text: String) {
        guard let url = dir?.appendingPathComponent(name) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func open(_ app: XCUIApplication) {
        app.tabBars.buttons["Apps"].tap()
        let card = app.scrollToModuleCard("household")
        XCTAssertTrue(card.exists)
        card.tap()
        XCTAssertTrue(app.navigationBars["Household"].waitForExistence(timeout: 6))
    }

    func testInviter() throws {
        try XCTSkipUnless(role == "inviter", "two-simulator run only")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
        open(app)
        app.buttons["household.empty.starter"].tap()
        XCTAssertTrue(app.buttons["household.check.Dishes"].waitForExistence(timeout: 4))

        app.segmentedControls["household.section"].buttons["Household"].tap()
        app.buttons["household.members.invite"].tap()
        let qr = app.images["household.invite.qr"]
        XCTAssertTrue(qr.waitForExistence(timeout: 6))
        let link = try XCTUnwrap(qr.value as? String, "the invite link")
        XCTAssertTrue(link.hasPrefix("snappet://household/join"), link)
        write("link.txt", link)

        XCTAssertTrue(app.staticTexts["household.invite.joined"].waitForExistence(timeout: 60), "the joiner arrived")
        app.buttons["household.invite.done"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Sam")).firstMatch
            .waitForExistence(timeout: 10), "Sam is a member")

        // Sam ticks the dishes on their phone; it should arrive here while both apps are open.
        write("inviter-ready.txt", "1")
        XCTAssertNotNil(waitForFile("joiner-ticked.txt", timeout: 60))
        app.segmentedControls["household.section"].buttons["Today"].tap()
        let done = NSPredicate(format: "label CONTAINS %@", "not done")
        let check = app.buttons["household.check.Dishes"]
        let arrived = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: check)], timeout: 30)
        if arrived != .completed {   // nudge: Sync now
            app.segmentedControls["household.section"].buttons["Household"].tap()
            app.buttons["household.members.syncNow"].tap()
            app.segmentedControls["household.section"].buttons["Today"].tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: done, object: check)], timeout: 30),
                       .completed, "Sam's tick reached this phone: \(check.label)")
        write("inviter-done.txt", "1")
    }

    func testJoiner() throws {
        try XCTSkipUnless(role == "joiner", "two-simulator run only")
        continueAfterFailure = false
        let link = try XCTUnwrap(waitForFile("link.txt", timeout: 120), "the inviter's link")
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
        open(app)   // creates this phone's (solo) household
        app.open(try XCTUnwrap(URL(string: link)))

        let name = app.textFields["household.join.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the join confirm sheet")
        name.tap()
        name.typeText("Sam")
        app.buttons["household.join.confirm"].tap()
        XCTAssertTrue(app.staticTexts["household.join.done"].waitForExistence(timeout: 40),
                      app.staticTexts["household.join.error"].exists ? app.staticTexts["household.join.error"].label : "timed out")
        app.buttons["household.join.close"].tap()

        let check = app.buttons["household.check.Dishes"]
        XCTAssertTrue(check.waitForExistence(timeout: 6), "the inviter's board arrived")
        XCTAssertNotNil(waitForFile("inviter-ready.txt", timeout: 60))
        check.tap()
        write("joiner-ticked.txt", "1")
        XCTAssertNotNil(waitForFile("inviter-done.txt", timeout: 90), "the inviter saw the tick")
    }
}
