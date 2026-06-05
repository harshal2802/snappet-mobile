import XCTest
@testable import Snappet

/// Unit tests for the **pure** receipt-text parser (`ReceiptParser`). Driven by real
/// Costco receipt lines: item rows (with leading item-codes and trailing tax flags),
/// instant-savings discount rows, and the SUBTOTAL / TAX / TOTAL summary rows.
final class ReceiptParserTests: XCTestCase {

    func testExtractsItemsStrippingCodesAndFlags() {
        let text = """
        E 1932071 LIQUIDIV LLS 28.99 E
        2015573 CHSEBRGRCAP 11.99 A
        689917 KING HAWAII 5.59 E
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.map(\.name), ["LIQUIDIV LLS", "CHSEBRGRCAP", "KING HAWAII"])
        XCTAssertEqual(r.items.map(\.price), [28.99, 11.99, 5.59])
        XCTAssertTrue(r.items.allSatisfy { $0.assignees.isEmpty }, "parser leaves assignment to the UI")
    }

    func testInstantSavingsBecomeDiscountNotItems() {
        let text = """
        F 1877320 VC SPF 50 19.99 A
        0000378710 / 1877320 4.00-A
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.items.first?.name, "VC SPF 50")
        XCTAssertEqual(r.discount, 4.00, accuracy: 0.0001)
    }

    func testCapturesTaxAndGrandTotal() {
        let text = """
        SUBTOTAL 605.09
        TAX 14.01
        **** TOTAL 619.10
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.tax ?? -1, 14.01, accuracy: 0.0001)
        XCTAssertEqual(r.total ?? -1, 619.10, accuracy: 0.0001)
        XCTAssertTrue(r.items.isEmpty, "summary rows are not items")
    }

    func testSummaryAndPaymentRowsAreNotItems() {
        let text = """
        2027490 ORGAINA2 27.99 E
        SUBTOTAL 605.09
        TAX 14.01
        **** TOTAL 619.10
        Visa 619.10
        CHANGE 0.00
        TOTAL NUMBER OF ITEMS SOLD = 51
        AMOUNT: $619.10
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.map(\.name), ["ORGAINA2"])
        XCTAssertEqual(r.items.first?.price ?? -1, 27.99, accuracy: 0.0001)
        XCTAssertEqual(r.total ?? -1, 619.10, accuracy: 0.0001)
    }

    // Regression: tax must come from the authoritative "TOTAL TAX" line, not the last TAX-bearing
    // line (per-rate "% Tax" and "FSA TAX" lines would otherwise clobber it). See review Bug 1.
    func testTaxPrefersTotalTaxIgnoringComponentAndFSALines() {
        let text = """
        SUBTOTAL 605.09
        TAX 14.01
        **** TOTAL 619.10
        A 10.25% Tax 6.81
        B 2.25% TAX 1.12
        E 1.25% TAX 6.08
        TOTAL TAX 14.01
        FSA TAX = 1.64
        FSA TOTAL = 17.63
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.tax ?? -1, 14.01, accuracy: 0.0001, "must not be clobbered by % / FSA lines")
        XCTAssertEqual(r.total ?? -1, 619.10, accuracy: 0.0001, "FSA TOTAL must not become the grand total")
        XCTAssertEqual(r.subtotal ?? -1, 605.09, accuracy: 0.0001)
    }

    func testDetectsSubtotalAndItemCount() {
        let text = """
        SUBTOTAL 605.09
        **** TOTAL 619.10
        Items Sold: 51
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.subtotal ?? -1, 605.09, accuracy: 0.0001)
        XCTAssertEqual(r.itemCount, 51)
    }

    // Regression: a leading-minus amount ("-4.00") is a discount, not a dropped line. See Bug 2.
    func testLeadingMinusIsADiscount() {
        let text = """
        APPLES 5.00
        COUPON -4.00
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.map(\.name), ["APPLES"])
        XCTAssertEqual(r.discount, 4.00, accuracy: 0.0001)
    }

    func testHandlesAttachedTaxFlagAndCommas() {
        let text = "100 BIG TICKET 1,234.50 A"
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.first?.name, "BIG TICKET")
        XCTAssertEqual(r.items.first?.price ?? -1, 1234.50, accuracy: 0.0001)
    }

    // Regression: a product whose name merely *contains* a summary word ("TOTAL", "TAX",
    // "AMOUNT") must stay an item — only a leading-label row is a summary row. See review finding #1.
    func testItemsNamedLikeSummaryWordsAreNotDropped() {
        let text = """
        96101 COLGATE TOTAL 5.99 A
        2027490 BODY WASH AMOUNT 8.49 E
        SUBTOTAL 14.48
        TAX 1.00
        **** TOTAL 15.48
        """
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.map(\.name), ["COLGATE TOTAL", "BODY WASH AMOUNT"],
                       "items whose names contain TOTAL/AMOUNT must not be swallowed as summary rows")
        XCTAssertEqual(r.items.map(\.price), [5.99, 8.49])
        XCTAssertEqual(r.subtotal ?? -1, 14.48, accuracy: 0.0001)
        XCTAssertEqual(r.tax ?? -1, 1.00, accuracy: 0.0001)
        XCTAssertEqual(r.total ?? -1, 15.48, accuracy: 0.0001, "the real leading-label TOTAL still wins")
    }

    func testBlankAndNoiseLinesIgnored() {
        let text = """

        Chicago (S. Loop) #1107
        RB Member 111945773512

        38742 SWEET CORN 4.99 E
        """
        let r = ReceiptParser.parse(text)
        // Address / member lines have no trailing 2-decimal price → skipped.
        XCTAssertEqual(r.items.map(\.name), ["SWEET CORN"])
    }
}
