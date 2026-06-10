import XCTest

/// End-to-end UI flow for Split Expenses: create a group, add an expense, edit its
/// amount, then record a manual settlement equal to the suggested transfer and assert
/// the pair clears. Mirrors the suite's Button-driven, accessibility-identifier style.
/// Screenshots each step; extract with `xcresulttool export attachments`.
final class ExpenseUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Type into a field after clearing whatever it holds.
    private func setField(_ field: XCUIElement, to text: String) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    func testEditAndSettleFlow() {
        // Open the Split Expenses mini-app from the App Library.
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.expense"]
        // Expense is in the Finance section (below the fold); the LazyVGrid may not realize the
        // card until scrolled near, so scroll until it exists, then until it's hittable.
        var tries = 0
        while !card.exists && tries < 10 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have the expense card")
        tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
        snap("01-expense-root")

        // Create a group with two participants: Alice and Bob.
        let newGroup = app.buttons["expense.newGroup"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 6), "New Group button should exist")
        newGroup.tap()

        setField(app.textFields["expense.group.name"], to: "Trip")
        setField(app.textFields["expense.group.participant.0"], to: "Alice")
        setField(app.textFields["expense.group.participant.1"], to: "Bob")
        app.buttons["expense.group.save"].tap()
        snap("02-group-created")

        // Open the group. A row tap that lands while the create-group sheet is still dismissing
        // can be swallowed, so retry until the group detail (its actions menu) appears.
        let groupRow = app.buttons.matching(identifier: "expenseGroupRow").firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 6), "the created group row should appear")
        let groupActions = app.buttons["expense.groupActions"]
        var openTries = 0
        while !groupActions.exists && openTries < 5 {
            groupRow.tap()
            _ = groupActions.waitForExistence(timeout: 2)
            openTries += 1
        }
        snap("03-group-detail")

        // Add an expense: Alice paid 100, split between both → Bob owes Alice 50.
        // Add Expense is a direct one-tap toolbar button now (issue #82), not a menu item.
        let newExpense = app.buttons["expense.newExpense"]
        XCTAssertTrue(newExpense.waitForExistence(timeout: 6), "Add Expense should be a direct button")
        newExpense.tap()

        setField(app.textFields["expense.expense.title"], to: "Dinner")
        setField(app.textFields["expense.expense.amount"], to: "100")
        app.buttons["expense.expense.save"].tap()
        snap("04-expense-added")

        // The settle-up plan should now suggest Bob owes Alice — and read in the second
        // person: creating the group stored slot 1 ("Alice") as the user's own name.
        XCTAssertTrue(app.staticTexts["Bob owes you"].waitForExistence(timeout: 6),
                      "settle-up plan should show Bob owing the user after a split expense")

        // Edit the expense amount to 60 → Bob now owes Alice 30.
        let expenseRow = app.staticTexts["Dinner"].firstMatch
        XCTAssertTrue(expenseRow.waitForExistence(timeout: 6), "the expense row should exist")
        expenseRow.tap()
        let amountField = app.textFields["expense.expense.amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 6), "edit sheet should open with the amount field")
        setField(amountField, to: "60")
        app.buttons["expense.expense.save"].tap()
        snap("05-expense-edited")

        XCTAssertTrue(app.staticTexts["Bob owes you"].waitForExistence(timeout: 6),
                      "edited expense should still show Bob owing the user")

        // Record the settlement by TAPPING the computed transfer (issue #82): the sheet
        // opens prefilled with payer=Bob, recipient=Alice, amount=30 — save in one tap.
        let transferRow = app.buttons["expense.transfer.Bob.Alice"]
        XCTAssertTrue(transferRow.waitForExistence(timeout: 6), "transfer row should be tappable")
        transferRow.tap()
        let settleSave = app.buttons["expense.settle.save"]
        XCTAssertTrue(settleSave.waitForExistence(timeout: 6), "prefilled settlement sheet should open")
        XCTAssertTrue(app.staticTexts["Bob paid Alice $30.00."].waitForExistence(timeout: 4)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Bob paid Alice")).firstMatch.exists,
                      "the sheet should be prefilled from the tapped transfer")
        settleSave.tap()
        snap("06-settled")

        // With a settlement equal to the suggested transfer, the pair is settled.
        XCTAssertTrue(app.staticTexts["All settled up"].waitForExistence(timeout: 6),
                      "a settlement equal to the suggested transfer should clear the pair")
    }
}
