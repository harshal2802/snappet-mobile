import Foundation

/// Pure, device-free guess of a receipt's `ReceiptType` from its text — backs the `.auto` option.
/// It scores each type by how many of its signature keywords appear and picks the best; ties or
/// no hits fall back to `.generic`. Kept free of SwiftUI/SwiftData so it runs in `SnappetTests`.
enum ReceiptClassifier {

    /// Signature keywords per type (uppercased substrings). Order also breaks ties (earlier wins).
    private static let signatures: [(ReceiptType, [String])] = [
        (.restaurant, ["SERVER", "GRATUITY", "TABLE", "GUEST", "DINE", "CHECK #"]),
        (.gas, ["GALLON", "UNLEADED", "PUMP", "FUEL", "DIESEL", "PRICE/GAL"]),
        (.warehouse, ["WHOLESALE", "MEMBER", "INSTANT SAVINGS", "COSTCO", "SAM'S CLUB", "BJ'S"]),
        (.pharmacy, ["PHARMACY", "PRESCRIPTION", "RX ", "NDC", "REFILL", "COPAY"]),
        (.grocery, ["GROCERY", "PRODUCE", "SUPERMARKET", "SAFEWAY", "KROGER", "TRADER JOE"]),
    ]

    static func classify(_ text: String) -> ReceiptType {
        let upper = text.uppercased()
        var best: ReceiptType = .generic
        var bestScore = 0
        for (type, keywords) in signatures {
            let score = keywords.reduce(0) { $0 + (upper.contains($1) ? 1 : 0) }
            if score > bestScore {
                bestScore = score
                best = type
            }
        }
        return bestScore > 0 ? best : .generic
    }
}
