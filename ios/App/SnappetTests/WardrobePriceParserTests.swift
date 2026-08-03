import XCTest
@testable import Snappet

/// The offline price-extraction floor (wardrobe prompt 05). This is the half of the price feature
/// that can be tested without a network or an AI-capable device, so it carries the weight.
final class WardrobePriceParserTests: XCTestCase {

    typealias Parser = WardrobePriceParser

    // MARK: strategy precedence

    /// Structured metadata must win over a regex across rendered markup. A page showing a
    /// crossed-out list price would otherwise report the wrong number with total confidence.
    func testJSONLDBeatsVisibleMarkup() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@type":"Product","name":"Tank","offers":{"@type":"Offer","price":"24.90","priceCurrency":"USD"}}
        </script></head>
        <body><span class="was">$32.00</span><span class="now">$24.90</span></body></html>
        """
        let result = Parser.parse(html: html)
        XCTAssertEqual(result?.amount, 24.90)
        XCTAssertEqual(result?.currencyCode, "USD")
        XCTAssertEqual(result?.source, .jsonLD)
    }

    func testOpenGraphUsedWhenThereIsNoJSONLD() {
        let html = """
        <meta property="product:price:amount" content="24.90">
        <meta property="product:price:currency" content="usd">
        <body>$99.00 free shipping over</body>
        """
        let result = Parser.parse(html: html)
        XCTAssertEqual(result?.amount, 24.90)
        XCTAssertEqual(result?.currencyCode, "USD", "currency is normalized to upper case")
        XCTAssertEqual(result?.source, .openGraph)
    }

    func testMetaAttributeOrderDoesNotMatter() {
        let html = #"<meta content="18.50" property="og:price:amount">"#
        XCTAssertEqual(Parser.parse(html: html)?.amount, 18.50)
    }

    func testMicrodataIsReadWhenItIsAllThereIs() {
        let html = #"<span itemprop="price" content="42.00"></span><meta itemprop="priceCurrency" content="EUR">"#
        let result = Parser.parse(html: html)
        XCTAssertEqual(result?.amount, 42.00)
        XCTAssertEqual(result?.currencyCode, "EUR")
        XCTAssertEqual(result?.source, .microdata)
    }

    /// The markup fallback takes the FIRST currency-marked number, not the smallest — the cheapest
    /// number on a product page is usually an instalment or a shipping threshold.
    func testMarkupFallbackTakesTheFirstPriceNotTheCheapest() {
        let html = "<body><h1>$59.00</h1><p>or 4 payments of $14.75</p></body>"
        let result = Parser.parse(html: html)
        XCTAssertEqual(result?.amount, 59.00)
        XCTAssertEqual(result?.source, .markup)
    }

    func testMarkupFallbackHandlesNonDollarCurrencies() {
        XCTAssertEqual(Parser.parse(html: "<p>£12.99</p>")?.currencyCode, "GBP")
        XCTAssertEqual(Parser.parse(html: "<p>€8.50</p>")?.amount, 8.50)
        XCTAssertEqual(Parser.parse(html: "<p>₹1,299</p>")?.amount, 1299)
    }

    // MARK: nested JSON-LD shapes

    func testOffersAsAnArrayAndInsideAGraph() {
        let array = """
        <script type="application/ld+json">
        {"@graph":[{"@type":"Product","offers":[{"price":15.5,"priceCurrency":"USD"}]}]}
        </script>
        """
        XCTAssertEqual(Parser.parse(html: array)?.amount, 15.5)
    }

    func testJSONLDPriceAsANumberNotAString() {
        let html = #"<script type="application/ld+json">{"offers":{"price":30}}</script>"#
        XCTAssertEqual(Parser.parse(html: html)?.amount, 30)
    }

    /// Malformed JSON in one block must not abort the search — real pages ship several.
    func testBrokenJSONLDBlockDoesNotPreventLaterOnesFromParsing() {
        let html = """
        <script type="application/ld+json">{ this is not json </script>
        <script type="application/ld+json">{"offers":{"price":"11.00"}}</script>
        """
        XCTAssertEqual(Parser.parse(html: html)?.amount, 11.00)
    }

    // MARK: number parsing

    func testEuropeanDecimalCommaIsUnderstood() {
        XCTAssertEqual(Parser.number(from: "1.234,56"), 1234.56)
        XCTAssertEqual(Parser.number(from: "24,90"), 24.90)
    }

    func testThousandsSeparatorsAreStripped() {
        XCTAssertEqual(Parser.number(from: "1,234.56"), 1234.56)
        XCTAssertEqual(Parser.number(from: "1,299"), 1299)
    }

    func testCurrencySymbolsAndSpacingAreTolerated() {
        XCTAssertEqual(Parser.number(from: " $ 24.90 "), 24.90)
        XCTAssertEqual(Parser.number(from: "USD 24.90"), 24.90)
    }

    func testNonPricesAreRejected() {
        XCTAssertNil(Parser.number(from: ""))
        XCTAssertNil(Parser.number(from: "free"))
        XCTAssertNil(Parser.number(from: "0"), "a zero price is not a price")
        XCTAssertNil(Parser.number(from: "-5"))
    }

    // MARK: no price at all

    /// The case that must NOT invent a number — the caller keeps the previous price and timestamp.
    func testAPageWithNoPriceYieldsNil() {
        XCTAssertNil(Parser.parse(html: "<html><body><h1>Out of stock</h1></body></html>"))
        XCTAssertNil(Parser.parse(html: ""))
    }

    func testBareNumbersWithoutACurrencyMarkAreNotTreatedAsPrices() {
        XCTAssertNil(Parser.parse(html: "<p>100% cotton, 250 gsm, style 4821</p>"),
                     "unmarked numbers on a product page are specs, not prices")
    }
}
