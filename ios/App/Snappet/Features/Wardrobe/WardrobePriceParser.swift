import Foundation

// The PURE price-extraction floor (wardrobe prompt 05). Given a product page's HTML, find the
// price. No network, no Apple Intelligence, no platform imports — so every retailer shape that has
// ever broken this can be pinned as a test fixture.
//
// This is the *floor*, deliberately: `WardrobePriceService` always runs it, and only then lets an
// on-device Foundation Models pass refine the answer. Same contract as `WardrobeIntelligence` —
// the heuristic result is what ships when FM is unavailable, so the feature degrades instead of
// failing on a non-AI device.

enum WardrobePriceParser {

    struct Result: Equatable, Sendable {
        var amount: Double
        /// ISO 4217 when the page said so; nil when only a bare number was found.
        var currencyCode: String?
        /// Which strategy won — surfaced in tests and logs, not in the UI.
        var source: Source
    }

    enum Source: String, Equatable, Sendable {
        case jsonLD, openGraph, microdata, markup
    }

    /// Try each strategy in descending order of trustworthiness. Structured metadata beats a
    /// regex over rendered markup every time — a page's visible text is full of crossed-out list
    /// prices, "compare at" values and instalment amounts.
    static func parse(html: String) -> Result? {
        jsonLD(html) ?? openGraph(html) ?? microdata(html) ?? markup(html)
    }

    // MARK: - Strategies

    /// schema.org `Offer` inside a JSON-LD block: the only source that is unambiguous by design.
    static func jsonLD(_ html: String) -> Result? {
        for block in matches(in: html,
                             pattern: #"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#,
                             group: 1) {
            guard let data = block.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let found = findOffer(in: object) { return found }
        }
        return nil
    }

    /// `og:price:amount` / `product:price:amount` — widely emitted and rarely wrong.
    static func openGraph(_ html: String) -> Result? {
        let amount = metaContent(html, property: "product:price:amount")
            ?? metaContent(html, property: "og:price:amount")
        guard let amount, let value = number(from: amount) else { return nil }
        let code = metaContent(html, property: "product:price:currency")
            ?? metaContent(html, property: "og:price:currency")
        return Result(amount: value, currencyCode: code?.uppercased(), source: .openGraph)
    }

    /// Microdata `itemprop="price"`, either as a content attribute or element text.
    static func microdata(_ html: String) -> Result? {
        if let raw = firstMatch(in: html,
                                pattern: #"itemprop=["']price["'][^>]*content=["']([^"']+)["']"#,
                                group: 1), let value = number(from: raw) {
            let code = firstMatch(in: html,
                                  pattern: #"itemprop=["']priceCurrency["'][^>]*content=["']([^"']+)["']"#,
                                  group: 1)
            return Result(amount: value, currencyCode: code?.uppercased(), source: .microdata)
        }
        return nil
    }

    /// Last resort: a currency-marked number in the markup. Takes the FIRST match rather than the
    /// smallest — "cheapest number on the page" is usually an instalment ("4 payments of $8.25")
    /// or a shipping threshold, not the price.
    static func markup(_ html: String) -> Result? {
        let symbols: [(String, String)] = [("$", "USD"), ("£", "GBP"), ("€", "EUR"), ("₹", "INR")]
        for (symbol, code) in symbols {
            let pattern = "\(NSRegularExpression.escapedPattern(for: symbol))\\s?([0-9][0-9,]*(?:\\.[0-9]{1,2})?)"
            if let raw = firstMatch(in: html, pattern: pattern, group: 1),
               let value = number(from: raw) {
                return Result(amount: value, currencyCode: code, source: .markup)
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Walk a decoded JSON-LD graph for the first `price` under an offer-ish node.
    private static func findOffer(in object: Any) -> Result? {
        if let dict = object as? [String: Any] {
            // `offers` may be an object or an array; `price` may be String or Number.
            if let price = dict["price"], let value = numberFromJSON(price) {
                let code = (dict["priceCurrency"] as? String)?.uppercased()
                return Result(amount: value, currencyCode: code, source: .jsonLD)
            }
            for key in ["offers", "@graph", "hasVariant", "itemOffered"] {
                if let child = dict[key], let found = findOffer(in: child) { return found }
            }
            for value in dict.values {
                if value is [String: Any] || value is [Any],
                   let found = findOffer(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for element in array {
                if let found = findOffer(in: element) { return found }
            }
        }
        return nil
    }

    private static func numberFromJSON(_ any: Any) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return number(from: s) }
        return nil
    }

    /// Parse a price string tolerantly: strips currency symbols, spaces and thousands separators.
    /// Handles the European "1.234,56" form by detecting which separator comes last.
    static func number(from raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        guard !s.isEmpty else { return nil }
        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")
        if let lastComma, let lastDot {
            if lastComma > lastDot {            // 1.234,56 → comma is the decimal mark
                s = s.replacingOccurrences(of: ".", with: "")
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {                            // 1,234.56
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if lastComma != nil {
            // Only commas: decimal mark if exactly two trailing digits, else thousands.
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            s = (parts.count == 2 && parts[1].count == 2)
                ? parts.joined(separator: ".")
                : s.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Double(s), value > 0, value.isFinite else { return nil }
        return value
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        // Either attribute order — `property` before `content` or after.
        return firstMatch(in: html,
                          pattern: "<meta[^>]*(?:property|name)=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']+)[\"']",
                          group: 1)
            ?? firstMatch(in: html,
                          pattern: "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(escaped)[\"']",
                          group: 1)
    }

    private static func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        matches(in: text, pattern: pattern, group: group).first
    }

    private static func matches(in text: String, pattern: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}
