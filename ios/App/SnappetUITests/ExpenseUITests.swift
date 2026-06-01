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

        // Open the group.
        let groupRow = app.buttons.matching(identifier: "expenseGroupRow").firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 6), "the created group row should appear")
        groupRow.tap()
        snap("03-group-detail")

        // Add an expense: Alice paid 100, split between both → Bob owes Alice 50.
        let groupActions = app.buttons["expense.groupActions"]
        XCTAssertTrue(groupActions.waitForExistence(timeout: 6), "group actions menu should exist")
        groupActions.tap()
        app.buttons["expense.newExpense"].tap()

        setField(app.textFields["expense.expense.title"], to: "Dinner")
        setField(app.textFields["expense.expense.amount"], to: "100")
        app.buttons["expense.expense.save"].tap()
        snap("04-expense-added")

        // The settle-up plan should now suggest Bob owes Alice.
        XCTAssertTrue(app.staticTexts["Bob owes Alice"].waitForExistence(timeout: 6),
                      "settle-up plan should show Bob owing Alice after a split expense")

        // Edit the expense amount to 60 → Bob now owes Alice 30.
        let expenseRow = app.staticTexts["Dinner"].firstMatch
        XCTAssertTrue(expenseRow.waitForExistence(timeout: 6), "the expense row should exist")
        expenseRow.tap()
        let amountField = app.textFields["expense.expense.amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 6), "edit sheet should open with the amount field")
        setField(amountField, to: "60")
        app.buttons["expense.expense.save"].tap()
        snap("05-expense-edited")

        XCTAssertTrue(app.staticTexts["Bob owes Alice"].waitForExistence(timeout: 6),
                      "edited expense should still show Bob owing Alice")

        // Record a settlement: Bob pays Alice 30 → the pair clears.
        groupActions.tap()
        app.buttons["expense.settle"].tap()

        // Settlement defaults payer=Alice, recipient=Bob; flip via the pickers so Bob pays Alice.
        app.buttons["expense.settle.payer"].tap()
        app.buttons["Bob"].firstMatch.tap()
        app.buttons["expense.settle.recipient"].tap()
        app.buttons["Alice"].firstMatch.tap()
        setField(app.textFields["expense.settle.amount"], to: "30")
        app.buttons["expense.settle.save"].tap()
        snap("06-settled")

        // With a settlement equal to the suggested transfer, the pair is settled.
        XCTAssertTrue(app.staticTexts["All settled up"].waitForExistence(timeout: 6),
                      "a settlement equal to the suggested transfer should clear the pair")
    }
}
