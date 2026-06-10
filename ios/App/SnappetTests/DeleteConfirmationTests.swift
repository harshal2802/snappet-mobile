import XCTest
@testable import Snappet

/// Pure logic behind the destructive-delete confirmations (prompt 34): the
/// impact-message pluralization for expense groups and budget categories, and the
/// shared blank-entry definition the Journal editor uses both on Done and on an
/// abandoned back-swipe.
final class DeleteConfirmationTests: XCTestCase {

    // MARK: - Expense group impact message

    func testExpenseGroupMessageEmpty() {
        XCTAssertEqual(ExpenseGroupDeleteImpact.message(recordCount: 0),
                       "This group has no expenses yet. This can't be undone.")
    }

    func testExpenseGroupMessageSingular() {
        XCTAssertTrue(ExpenseGroupDeleteImpact.message(recordCount: 1).contains("1 expense, receipt, or settlement"))
    }

    func testExpenseGroupMessagePlural() {
        let message = ExpenseGroupDeleteImpact.message(recordCount: 12)
        XCTAssertTrue(message.contains("12 expenses, receipts, and settlements"))
    }

    // MARK: - Budget category impact message

    func testBudgetCategoryMessageEmpty() {
        XCTAssertEqual(BudgetCategoryDeleteImpact.message(transactionCount: 0),
                       "This category has no transactions. This can't be undone.")
    }

    func testBudgetCategoryMessageSingular() {
        XCTAssertTrue(BudgetCategoryDeleteImpact.message(transactionCount: 1).contains("1 transaction (across all months)"))
    }

    func testBudgetCategoryMessagePlural() {
        XCTAssertTrue(BudgetCategoryDeleteImpact.message(transactionCount: 23).contains("23 transactions (across all months)"))
    }

    // MARK: - Journal blank-entry definition

    func testBlankWhenAllFieldsEmpty() {
        XCTAssertTrue(JournalEntry.isBlank(title: "", body: "", tags: []))
    }

    func testWhitespaceOnlyCountsAsBlank() {
        XCTAssertTrue(JournalEntry.isBlank(title: "  \n", body: "\t \n ", tags: []))
    }

    func testTitleAloneIsContent() {
        XCTAssertFalse(JournalEntry.isBlank(title: "Morning", body: "", tags: []))
    }

    func testBodyAloneIsContent() {
        XCTAssertFalse(JournalEntry.isBlank(title: "", body: "Climbed today.", tags: []))
    }

    func testTagAloneIsContent() {
        XCTAssertFalse(JournalEntry.isBlank(title: "", body: "", tags: ["trip"]))
    }
}
