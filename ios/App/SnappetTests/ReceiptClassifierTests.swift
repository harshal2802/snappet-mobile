import XCTest
@testable import Snappet

/// Unit tests for the pure receipt-type classifier and the profile-aware parser branches.
final class ReceiptClassifierTests: XCTestCase {

    func testClassifiesWarehouse() {
        let text = "COSTCO WHOLESALE\nRB Member 111\nINSTANT SAVINGS 17.50"
        XCTAssertEqual(ReceiptClassifier.classify(text), .warehouse)
    }

    func testClassifiesRestaurant() {
        let text = "Server: Dana  Table 12\nGuests 3\nGRATUITY 18.00"
        XCTAssertEqual(ReceiptClassifier.classify(text), .restaurant)
    }

    func testClassifiesGas() {
        let text = "SHELL\nUNLEADED REGULAR\nGALLONS 12.345\nPRICE/GAL 3.499"
        XCTAssertEqual(ReceiptClassifier.classify(text), .gas)
    }

    func testFallsBackToGenericWhenNothingMatches() {
        XCTAssertEqual(ReceiptClassifier.classify("WIDGET 5.00\nGADGET 6.00"), .generic)
    }

    // MARK: - Profile-aware parsing

    func testRestaurantTipBecomesALineItemAndServerLinesSkipped() {
        let text = """
        Server: Dana
        Table 12
        Burger 14.00
        Fries 6.00
        TIP 4.00
        TOTAL 24.00
        """
        let r = ReceiptParser.parse(text, profile: ReceiptType.restaurant.profile)
        XCTAssertEqual(r.items.map(\.name), ["Burger", "Fries", "Tip"])
        XCTAssertEqual(r.items.last?.price ?? -1, 4.00, accuracy: 0.0001)
        XCTAssertEqual(r.total ?? -1, 24.00, accuracy: 0.0001)
    }

    func testGasCollapsesToASingleFuelItem() {
        let text = """
        SHELL
        UNLEADED REGULAR
        GALLONS 12.345
        PRICE/GAL 3.499
        TOTAL 43.20
        """
        let r = ReceiptParser.parse(text, profile: ReceiptType.gas.profile)
        XCTAssertEqual(r.items.map(\.name), ["Fuel"])
        XCTAssertEqual(r.items.first?.price ?? -1, 43.20, accuracy: 0.0001)
    }

    func testGenericProfileIsUnchangedDefault() {
        // The default profile must parse a Costco-style line exactly as before.
        let r = ReceiptParser.parse("2015573 CHSEBRGRCAP 11.99 A")
        XCTAssertEqual(r.items.map(\.name), ["CHSEBRGRCAP"])
    }
}
