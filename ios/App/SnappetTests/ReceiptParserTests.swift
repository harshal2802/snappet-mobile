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

    func testHandlesAttachedTaxFlagAndCommas() {
        let text = "100 BIG TICKET 1,234.50 A"
        let r = ReceiptParser.parse(text)
        XCTAssertEqual(r.items.first?.name, "BIG TICKET")
        XCTAssertEqual(r.items.first?.price ?? -1, 1234.50, accuracy: 0.0001)
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
