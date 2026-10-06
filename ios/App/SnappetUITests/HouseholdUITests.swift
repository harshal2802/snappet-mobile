import XCTest

/// Household P1 (prompt 156): add a chore, set the house goal, tick the chore, and watch the goal move.
/// Persistence across launches is covered by `HouseholdStoreTests` (UI tests run on an in-memory store).
final class HouseholdUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func openHousehold() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.scrollToModuleCard("household")
        XCTAssertTrue(card.exists, "App Library should have the Household card")
        card.tap()
        XCTAssertTrue(app.navigationBars["Household"].waitForExistence(timeout: 6), "Household root should open")
    }

    func testAddChoreSetGoalTickAndTheGoalMoves() {
        openHousehold()

        app.buttons["household.empty.add"].tap()
        let name = app.textFields["household.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        name.tap()
        name.typeText("Dishes")
        app.buttons["household.editor.repeats"].tap()
        app.buttons["Daily"].firstMatch.tap()
        app.buttons["household.editor.save"].tap()

        let check = app.buttons["household.check.Dishes"]
        XCTAssertTrue(check.waitForExistence(timeout: 4), "the new daily chore is yours today")

        app.buttons["household.goal.card"].tap()
        let stepper = app.steppers["household.goal.target"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 4))
        for _ in 0..<15 { stepper.buttons.element(boundBy: 0).tap() }   // decrement 20 → 5
        let reward = app.textFields["household.goal.reward"]
        reward.tap()
        reward.typeText("Pizza")
        app.buttons["household.goal.save"].tap()

        // The goal card is one button; its texts read as its label.
        let card = app.buttons["household.goal.card"]
        func cardSays(_ text: String) -> Bool {
            let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: card)
            return XCTWaiter.wait(for: [e], timeout: 4) == .completed
        }
        XCTAssertTrue(cardSays("0 of 5 chores → Pizza"), card.label)

        check.tap()
        XCTAssertTrue(cardSays("1 of 5 chores → Pizza"), "ticking moves the goal: \(card.label)")

        // Untick puts it back.
        app.buttons["household.check.Dishes"].tap()
        XCTAssertTrue(cardSays("0 of 5 chores → Pizza"), card.label)
    }

    func testStarterChoresFillTheBoard() {
        openHousehold()
        app.buttons["household.empty.starter"].tap()
        XCTAssertTrue(app.buttons["household.check.Dishes"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["household.claim.Clean the fridge"].exists, "never-done fridge is up for grabs")
        app.segmentedControls["household.section"].buttons["All chores"].tap()
        XCTAssertTrue(app.staticTexts["Water plants"].waitForExistence(timeout: 4))
        app.segmentedControls["household.section"].buttons["Week"].tap()
        XCTAssertTrue(app.staticTexts["The house this week"].waitForExistence(timeout: 4)
                      || app.staticTexts["THE HOUSE THIS WEEK"].exists)
    }
}
