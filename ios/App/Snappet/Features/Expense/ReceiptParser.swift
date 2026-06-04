import Foundation

/// Pure, device-free parser that turns pasted/scanned receipt text into line items plus
/// the detected tax, discount and total. Heuristic by necessity — receipts vary wildly —
/// but the rules are simple and unit-tested against a real Costco receipt:
///
///  - A line item is a row ending in a money amount (e.g. `LIQUIDIV LLS  28.99 E`). The
///    last money token on the line is the price; leading item-codes (bare integers) and a
///    leading single-letter tax flag are stripped from the name.
///  - A trailing-minus amount (`4.00-`) is an instant-savings/discount line and is summed
///    into `discount` rather than added as an item.
///  - Summary rows — SUBTOTAL / TAX / TOTAL / payment / membership lines — are not items;
///    the tax and grand-total values are captured from them when present.
///
/// Kept free of SwiftUI/SwiftData so it runs in `SnappetTests` with no simulator.
enum ReceiptParser {

    struct ParsedReceipt: Equatable {
        var items: [ReceiptItem]
        var discount: Double
        var tax: Double?
        var total: Double?
    }

    /// Keyword fragments that mark a line as a receipt summary / metadata row rather than a
    /// purchasable item. Matched case-insensitively as substrings.
    private static let skipKeywords = [
        "SUBTOTAL", "TOTAL", "TAX", "CHANGE", "BALANCE", "VISA", "MASTERCARD",
        "DEBIT", "CREDIT", "AMOUNT", "INSTANT SAVINGS", "MEMBER", "CHIP READ",
        "APPROVED", "RESP", "TRAN", "AID", "SEQ", "APP#", "ITEMS SOLD", "FSA",
        "COUNT", "BOTTOM OF BASKET", "THANK YOU", "PLEASE COME", "OP#", "WHSE",
        "TRM", "TRN", "WHOLESALE", "PURCHASE", "ITEM",
    ]

    static func parse(_ text: String) -> ParsedReceipt {
        var items: [ReceiptItem] = []
        var discount = 0.0
        var tax: Double?
        var total: Double?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()

            guard let money = lastMoney(in: line) else { continue }

            // Discount / instant-savings rows (trailing minus) — credit, don't itemize.
            if money.isNegative {
                discount += money.value
                continue
            }

            // Summary / metadata rows: capture tax & grand total, never itemize.
            if skipKeywords.contains(where: { upper.contains($0) }) {
                // "TOTAL TAX 14.01" or a line that is just the tax.
                if upper.contains("TAX") && !upper.contains("N/TAX") {
                    tax = money.value
                } else if upper.contains("TOTAL")
                            && !upper.contains("SUBTOTAL")
                            && !upper.contains("NUMBER")
                            && !upper.contains("BOB") {
                    // Prefer the largest total seen (the grand total, not a card line).
                    total = max(total ?? 0, money.value)
                }
                continue
            }

            let name = cleanName(line, priceToken: money.token)
            guard !name.isEmpty else { continue }
            items.append(ReceiptItem(name: name, price: money.value))
        }

        return ParsedReceipt(items: items, discount: discount, tax: tax, total: total)
    }

    // MARK: - Money scanning

    private struct Money { let value: Double; let isNegative: Bool; let token: String }

    /// The last money-looking token on a line (e.g. `28.99`, `$1,234.50`, `4.00-`).
    private static func lastMoney(in line: String) -> Money? {
        var found: Money?
        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let money = money(from: String(token)) { found = money }
        }
        return found
    }

    private static func money(from token: String) -> Money? {
        var t = token
        // Drop a trailing single tax-flag letter (Costco appends A/B/E/F to amounts,
        // sometimes attached: "28.99E", "4.00-A").
        if let last = t.last, last.isLetter, t.count > 1 { t.removeLast() }
        let isNegative = t.hasSuffix("-")
        if isNegative { t.removeLast() }
        t = t.replacingOccurrences(of: "$", with: "")
             .replacingOccurrences(of: ",", with: "")
        // Require an explicit two-decimal money shape so bare item-codes aren't prices.
        guard let dot = t.firstIndex(of: "."),
              t.distance(from: dot, to: t.endIndex) == 3,
              t.dropFirst(t.distance(from: t.startIndex, to: dot) + 1).allSatisfy(\.isNumber),
              t[..<dot].allSatisfy(\.isNumber),
              !t[..<dot].isEmpty,
              let value = Double(t) else { return nil }
        return Money(value: value, isNegative: isNegative, token: token)
    }

    /// Strip everything from the price token onward, then drop a leading single-letter tax
    /// flag and any leading bare item-code integers, leaving the product description.
    private static func cleanName(_ line: String, priceToken: String) -> String {
        var head = line
        if let range = line.range(of: priceToken) {
            head = String(line[..<range.lowerBound])
        }
        var tokens = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Leading single-letter tax flag (Costco prefixes some rows with E/F).
        if let first = tokens.first, first.count == 1, first.allSatisfy(\.isLetter) {
            tokens.removeFirst()
        }
        // Leading bare item-codes (pure digits, possibly with a stray '/').
        while let first = tokens.first,
              first.allSatisfy({ $0.isNumber || $0 == "/" }),
              first.contains(where: \.isNumber) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
