import XCTest
@testable import Snappet

/// Unit tests for the pure receipt cross-check (`ReceiptValidation`) — verifies that the
/// captured items reconcile with the totals printed on the receipt.
final class ReceiptValidationTests: XCTestCase {

    private func item(_ name: String, _ price: Double, _ who: [String]) -> ReceiptItem {
        ReceiptItem(name: name, price: price, assignees: who)
    }

    private func report(items: [ReceiptItem], tax: Double = 0, discount: Double = 0,
                        subtotal: Double? = nil, detectedTax: Double? = nil,
                        total: Double? = nil, count: Int? = nil) -> ReceiptValidation.Report {
        let result = ReceiptSplit.compute(items: items, taxAmount: tax, discountAmount: discount,
                                          order: ["Alice", "Bob"])
        return ReceiptValidation.validate(result: result, detectedSubtotal: subtotal,
                                          detectedTax: detectedTax, detectedTotal: total,
                                          detectedItemCount: count,
                                          lineItemCount: items.filter { $0.price > 0 }.count)
    }

    private func status(_ r: ReceiptValidation.Report, _ id: String) -> ReceiptValidation.Status? {
        r.checks.first { $0.id == id }?.status
    }

    func testBalancedWhenItemsTaxMatchTotal() {
        // 30 items + 3 tax = 33 total.
        let r = report(items: [item("A", 10, ["Alice"]), item("B", 20, ["Bob"])],
                       tax: 3, subtotal: 30, total: 33)
        XCTAssertEqual(r.overall, .pass)
        XCTAssertEqual(status(r, "total"), .pass)
        XCTAssertEqual(status(r, "subtotal"), .pass)
    }

    func testFailsWhenTotalDoesNotReconcile() {
        // Items sum to 30 (+3 tax = 33) but the receipt says 45 — a dropped item.
        let r = report(items: [item("A", 10, ["Alice"]), item("B", 20, ["Bob"])],
                       tax: 3, total: 45)
        XCTAssertEqual(r.overall, .fail)
        XCTAssertEqual(status(r, "total"), .fail)
    }

    func testDiscountIncludedInReconciliation() {
        // 20 items − 4 discount + 0 tax = 16 total.
        let r = report(items: [item("A", 10, ["Alice"]), item("B", 10, ["Bob"])],
                       discount: 4, total: 16)
        XCTAssertEqual(status(r, "total"), .pass)
    }

    func testWarnsWhenNoTotalDetected() {
        let r = report(items: [item("A", 10, ["Alice"])])
        XCTAssertEqual(status(r, "total"), .warn)
        XCTAssertEqual(r.overall, .warn)
    }

    func testUnassignedItemsWarn() {
        // Both items are on the receipt (total 16, so the total still reconciles), but one item
        // hasn't been assigned to anyone yet — that's a split-completeness warning, not a total error.
        let r = report(items: [item("A", 10, ["Alice"]), item("B", 6, [])], total: 16)
        XCTAssertEqual(status(r, "total"), .pass)
        XCTAssertEqual(status(r, "unassigned"), .warn)
        XCTAssertEqual(r.overall, .warn)
    }

    func testItemCountMismatchWarns() {
        let r = report(items: [item("A", 10, ["Alice"])], total: 10, count: 3)
        XCTAssertEqual(status(r, "count"), .warn)
    }

    func testTaxMismatchWarns() {
        // Entered tax 3 but the receipt printed 5.
        let r = report(items: [item("A", 30, ["Alice"])], tax: 3, detectedTax: 5, total: 33)
        XCTAssertEqual(status(r, "tax"), .warn)
    }
}
