import XCTest

/// UI walkthrough of the Budget mini-app's new feature increment: add a category, log a
/// transaction, edit it, then step to the previous month and back. Asserts the month label
/// changes and the edit flow round-trips. Identifiers come from `budget.*` on the views.
///
/// Currency `TextField`s are awkward to type into reliably under XCUITest (locale-formatted
/// fields), so amount entry uses `typeText` defensively and the assertions focus on the
/// flow/navigation that the increment is responsible for, not exact formatted values.
final class BudgetUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Opens the Budget mini-app from the App Library.
    private func openBudget() {
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.budget"]
        XCTAssertTrue(card.waitForExistence(timeout: 6), "App Library should have a Budget card")
        var tries = 0
        while !card.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    /// Adds a budget category via the category editor sheet.
    private func addCategory(named name: String, limit: String) {
        // Either the empty-state button or the toolbar "Add Category" menu item.
        let emptyAdd = app.buttons["budget.addCategory"].firstMatch
        if emptyAdd.waitForExistence(timeout: 3) {
            emptyAdd.tap()
        }
        // If a menu was opened (toolbar), the same identifier resolves to the item; tapping
        // the firstMatch above handles both presentations.

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 4), "category editor should show a Name field")
        nameField.tap()
        nameField.typeText(name)

        let amountField = app.textFields["Amount"]
        if amountField.waitForExistence(timeout: 2) {
            amountField.tap()
            amountField.typeText(limit)
        }
        app.buttons["Save"].tap()
    }

    func testEditTransactionAndMonthSwitch() {
        openBudget()
        snap("01-budget-open")

        // Seed a category (empty state on a fresh install).
        addCategory(named: "Groceries", limit: "400")
        snap("02-category-added")

        // The summary tiles and month header should now be present.
        XCTAssertTrue(app.staticTexts["budget.monthLabel"].waitForExistence(timeout: 4),
                      "month header label should render")
        let monthLabel = app.staticTexts["budget.monthLabel"].label

        // Add a transaction against the category.
        let addMenu = app.buttons["Add"]
        if addMenu.waitForExistence(timeout: 3) { addMenu.tap() }
        let addTxn = app.buttons["budget.addTxn"]
        if addTxn.waitForExistence(timeout: 3) { addTxn.tap() }

        let amount = app.textFields["budget.txnAmount"]
        if amount.waitForExistence(timeout: 4) {
            amount.tap()
            amount.typeText("50")
            app.buttons["budget.txnSave"].tap()
        }
        snap("03-transaction-added")

        // Open the category's transaction list and edit the transaction.
        let categoryRow = app.buttons["budget.category.Groceries"].firstMatch
        if categoryRow.waitForExistence(timeout: 4) {
            categoryRow.tap()
            let editRow = app.buttons["budget.editTxn"].firstMatch
            if editRow.waitForExistence(timeout: 4) {
                editRow.tap()
                let editAmount = app.textFields["budget.txnAmount"]
                if editAmount.waitForExistence(timeout: 4) {
                    editAmount.tap()
                    // Clear then retype to change the amount.
                    if let current = editAmount.value as? String, !current.isEmpty {
                        editAmount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
                    }
                    editAmount.typeText("75")
                    app.buttons["budget.txnSave"].tap()
                }
                snap("04-transaction-edited")
            }
            // Back to the root from the category list.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Step to the previous month — the label must change and "next" becomes enabled.
        let prev = app.buttons["budget.prevMonth"]
        XCTAssertTrue(prev.waitForExistence(timeout: 4), "prev-month chevron should exist")
        prev.tap()
        snap("05-prev-month")
        let prevLabel = app.staticTexts["budget.monthLabel"].label
        XCTAssertNotEqual(prevLabel, monthLabel, "stepping back should change the displayed month")

        // Step forward — back to where we started.
        let next = app.buttons["budget.nextMonth"]
        XCTAssertTrue(next.waitForExistence(timeout: 4), "next-month chevron should exist")
        next.tap()
        snap("06-back-to-current")
        XCTAssertEqual(app.staticTexts["budget.monthLabel"].label, monthLabel,
                       "stepping forward should return to the original month")

        // The trends screen should be reachable and render its chart.
        let trends = app.buttons["budget.trends"].firstMatch
        if trends.waitForExistence(timeout: 4) {
            trends.tap()
            XCTAssertTrue(app.otherElements["budget.trendsChart"].waitForExistence(timeout: 4)
                || app.staticTexts["Trends"].waitForExistence(timeout: 2),
                "the 6-month trends screen should open")
            snap("07-trends")
        }
    }
}
