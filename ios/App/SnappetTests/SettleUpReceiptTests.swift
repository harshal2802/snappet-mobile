import XCTest
@testable import Snappet

/// Unit tests that an itemized `ExpenseRecord` flows through `SettleUp.balances` correctly:
/// the payer is credited the grand total, each person is debited their `ReceiptSplit`
/// slice, and the group nets to zero. Even-split and settlement records are unaffected.
final class SettleUpReceiptTests: XCTestCase {

    private let group = ["Alice", "Bob", "Cara"]

    private func balance(_ balances: [SettleUp.Balance], _ name: String) -> Double {
        balances.first { $0.name == name }?.net ?? .nan
    }

    func testReceiptCreditsPayerAndDebitsSharers() {
        // Alice pays. Pizza shared by all (30 → 10 each); beer is Bob+Cara (20 → 10 each).
        let receipt = ExpenseRecord(
            groupID: UUID(), title: "Dinner", amount: 50, payer: "Alice",
            participants: group,
            items: [
                ReceiptItem(name: "Pizza", price: 30, assignees: group),
                ReceiptItem(name: "Beer", price: 20, assignees: ["Bob", "Cara"]),
            ]
        )
        let b = SettleUp.balances(participants: group, expenses: [receipt])
        // Alice paid 50, owes 10 → +40. Bob owes 10+10 → −20. Cara owes 10+10 → −20.
        XCTAssertEqual(balance(b, "Alice"), 40, accuracy: 0.0001)
        XCTAssertEqual(balance(b, "Bob"), -20, accuracy: 0.0001)
        XCTAssertEqual(balance(b, "Cara"), -20, accuracy: 0.0001)
        XCTAssertEqual(b.reduce(0) { $0 + $1.net }, 0, accuracy: 0.0001, "balances net to zero")
    }

    func testReceiptWithTaxAndDiscountNetsToZero() {
        let receipt = ExpenseRecord(
            groupID: UUID(), title: "Costco", amount: 0, payer: "Bob",
            participants: group,
            items: (0..<25).map { i in
                ReceiptItem(name: "Item \(i)", price: Double(i % 5) + 1.49,
                            assignees: Array(group.prefix((i % 3) + 1)))
            },
            taxAmount: 6.13, discountAmount: 4.20
        )
        let b = SettleUp.balances(participants: group, expenses: [receipt])
        XCTAssertEqual(b.reduce(0) { $0 + $1.net }, 0, accuracy: 0.0001)
        // The payer's credit equals the receipt grand total.
        let computed = ReceiptSplit.compute(items: receipt.items, taxAmount: receipt.taxAmount,
                                            discountAmount: receipt.discountAmount, order: group)
        let bobOwed = computed.perPerson.first { $0.name == "Bob" }?.total ?? 0
        XCTAssertEqual(balance(b, "Bob"), computed.grandTotal - bobOwed, accuracy: 0.0001)
    }

    func testEvenSplitStillWorksAlongsideReceipts() {
        let even = ExpenseRecord(groupID: UUID(), title: "Cab", amount: 30,
                                 payer: "Cara", participants: group)
        let b = SettleUp.balances(participants: group, expenses: [even])
        XCTAssertEqual(balance(b, "Cara"), 20, accuracy: 0.0001)
        XCTAssertEqual(balance(b, "Alice"), -10, accuracy: 0.0001)
    }
}
