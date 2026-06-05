import XCTest
@testable import Snappet

/// Unit tests for the **pure** itemized-receipt split math (`ReceiptSplit`). No device,
/// no SwiftData. The headline guarantee is *penny-perfect closure*: each column (tax,
/// discount, total) is reconciled so the per-person numbers sum exactly to the receipt's
/// grand total — which is what keeps the group's settle-up balances from drifting.
final class ReceiptSplitTests: XCTestCase {

    private func item(_ name: String, _ price: Double, _ who: [String]) -> ReceiptItem {
        ReceiptItem(name: name, price: price, assignees: who)
    }

    private func share(_ r: ReceiptSplit.Result, _ name: String,
                       file: StaticString = #filePath, line: UInt = #line) -> ReceiptSplit.PersonShare {
        if let s = r.perPerson.first(where: { $0.name == name }) { return s }
        XCTFail("no share for \(name)", file: file, line: line)
        return ReceiptSplit.PersonShare(name: name, itemsSubtotal: 0, tax: 0, discount: 0, total: 0)
    }

    // MARK: - Even split of a shared item

    func testSharedItemSplitsEvenly() {
        let r = ReceiptSplit.compute(items: [item("Pizza", 20, ["Alice", "Bob"])],
                                     order: ["Alice", "Bob"])
        XCTAssertEqual(share(r, "Alice").total, 10, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Bob").total, 10, accuracy: 0.0001)
        XCTAssertEqual(r.grandTotal, 20, accuracy: 0.0001)
    }

    // MARK: - Per-item assignment

    func testItemsChargedToTheirOwnAssignees() {
        let r = ReceiptSplit.compute(items: [
            item("Shared", 10, ["Alice", "Bob"]),   // 5 each
            item("Bob only", 20, ["Bob"]),          // Bob 20
        ], order: ["Alice", "Bob"])
        XCTAssertEqual(share(r, "Alice").total, 5, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Bob").total, 25, accuracy: 0.0001)
        XCTAssertEqual(r.itemsSubtotal, 30, accuracy: 0.0001)
    }

    // MARK: - Tax allocated proportionally to pre-tax share

    func testTaxIsProportional() {
        let r = ReceiptSplit.compute(items: [
            item("A", 5, ["Alice"]),    // subtotal 5
            item("B", 25, ["Bob"]),     // subtotal 25
        ], taxAmount: 3, order: ["Alice", "Bob"])
        // 3 split 5:25 → 0.50 / 2.50
        XCTAssertEqual(share(r, "Alice").tax, 0.50, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Bob").tax, 2.50, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Alice").total, 5.50, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Bob").total, 27.50, accuracy: 0.0001)
        XCTAssertEqual(r.grandTotal, 33, accuracy: 0.0001)
    }

    // MARK: - Discount credited proportionally

    func testDiscountIsCreditedProportionally() {
        let r = ReceiptSplit.compute(items: [
            item("A", 10, ["Alice"]),
            item("B", 10, ["Bob"]),
        ], discountAmount: 4, order: ["Alice", "Bob"])
        XCTAssertEqual(share(r, "Alice").discount, 2, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Bob").discount, 2, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Alice").total, 8, accuracy: 0.0001)
        XCTAssertEqual(r.grandTotal, 16, accuracy: 0.0001)
    }

    // MARK: - Penny reconciliation (odd cents still close to the grand total)

    func testThreeWaySplitReconcilesToExactTotal() {
        let r = ReceiptSplit.compute(items: [item("Cab", 10, ["Alice", "Bob", "Cara"])],
                                     order: ["Alice", "Bob", "Cara"])
        let sum = r.perPerson.reduce(0) { $0 + $1.total }
        XCTAssertEqual(sum, 10, accuracy: 0.0001, "per-person totals must sum to the exact total")
        XCTAssertEqual(r.grandTotal, 10, accuracy: 0.0001)
        for s in r.perPerson {
            XCTAssertTrue(s.total == 3.33 || s.total == 3.34, "got \(s.total)")
        }
    }

    func testRowsAreInternallyConsistent() {
        // Each row must satisfy: subtotal + tax − discount == total (to the cent).
        let r = ReceiptSplit.compute(items: [
            item("A", 7.77, ["Alice", "Bob", "Cara"]),
            item("B", 13.13, ["Bob", "Cara"]),
        ], taxAmount: 2.05, discountAmount: 1.11,
           order: ["Alice", "Bob", "Cara"])
        for s in r.perPerson {
            XCTAssertEqual(s.itemsSubtotal + s.tax - s.discount, s.total, accuracy: 0.0001)
        }
        let sum = r.perPerson.reduce(0) { $0 + $1.total }
        XCTAssertEqual(sum, r.grandTotal, accuracy: 0.0001)
    }

    // MARK: - Unassigned items

    func testUnassignedItemsAreNotCharged() {
        let r = ReceiptSplit.compute(items: [
            item("Mine", 10, ["Alice"]),
            item("Nobody's", 6, []),
        ], order: ["Alice"])
        XCTAssertEqual(r.unassignedSubtotal, 6, accuracy: 0.0001)
        XCTAssertEqual(share(r, "Alice").total, 10, accuracy: 0.0001)
        XCTAssertEqual(r.perPerson.count, 1)
        // Grand total only reflects what's actually attributed.
        XCTAssertEqual(r.grandTotal, 10, accuracy: 0.0001)
    }

    // MARK: - Display order

    func testRespectsRequestedOrderThenAppendsExtras() {
        let r = ReceiptSplit.compute(items: [
            item("A", 1, ["Zed"]),
            item("B", 1, ["Alice"]),
        ], order: ["Alice", "Bob"])
        // Alice is in order; Zed isn't and is appended after.
        XCTAssertEqual(r.perPerson.map(\.name), ["Alice", "Zed"])
    }

    // MARK: - Realistic large receipt closes to the cent

    func testManyItemsAndTaxStillCloseExactly() {
        var items: [ReceiptItem] = []
        let people = ["Alice", "Bob", "Cara"]
        for i in 0..<40 {
            let price = Double(i % 7) + 0.99    // messy prices
            let who = Array(people.prefix((i % 3) + 1))
            items.append(item("Item \(i)", price, who))
        }
        let r = ReceiptSplit.compute(items: items, taxAmount: 14.01,
                                     discountAmount: 17.50, order: people)
        let sum = r.perPerson.reduce(0) { $0 + $1.total }
        XCTAssertEqual(sum, r.grandTotal, accuracy: 0.0001)
        XCTAssertEqual(r.tax, 14.01, accuracy: 0.0001)
        XCTAssertEqual(r.discount, 17.50, accuracy: 0.0001)
    }
}
