import Foundation

/// The kind of receipt being scanned. Drives a `ReceiptProfile` that tunes how `ReceiptParser`
/// extracts line items vs. metadata (and how `ReceiptClassifier` guesses the type for `.auto`).
/// The type affects *parsing only* — the saved receipt is a plain itemized expense — so adding a
/// type needs no schema change.
enum ReceiptType: String, CaseIterable, Identifiable {
    case auto, grocery, warehouse, restaurant, gas, pharmacy, retail, generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .grocery: return "Grocery"
        case .warehouse: return "Warehouse"
        case .restaurant: return "Restaurant"
        case .gas: return "Gas"
        case .pharmacy: return "Pharmacy"
        case .retail: return "Retail"
        case .generic: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .grocery: return "cart"
        case .warehouse: return "shippingbox"
        case .restaurant: return "fork.knife"
        case .gas: return "fuelpump"
        case .pharmacy: return "cross.case"
        case .retail: return "bag"
        case .generic: return "doc.plaintext"
        }
    }

    /// Resolve a concrete type for `text`: `.auto` runs the classifier, anything else is itself.
    func resolved(for text: String) -> ReceiptType {
        self == .auto ? ReceiptClassifier.classify(text) : self
    }

    /// The parsing profile for this type (`.auto` falls back to generic — resolve first).
    var profile: ReceiptProfile {
        ReceiptProfile.forType(self == .auto ? .generic : self)
    }
}

/// Per-type tuning for `ReceiptParser`: which extra lines to treat as metadata, which lines are a
/// tip, and whether to collapse the receipt to a single fuel line. Pure value type.
struct ReceiptProfile: Equatable {
    /// Appended to the parser's base skip-keyword set (matched as uppercased substrings).
    let extraSkipKeywords: [String]
    /// A line whose uppercased text starts with one of these is recorded as a "Tip" line item.
    let tipKeywordPrefixes: [String]
    /// Gas: when no items parse, treat the detected total as a single "Fuel" line item.
    let fuelOnly: Bool

    static let generic = ReceiptProfile(extraSkipKeywords: [], tipKeywordPrefixes: [], fuelOnly: false)

    static func forType(_ type: ReceiptType) -> ReceiptProfile {
        switch type {
        case .restaurant:
            return ReceiptProfile(
                extraSkipKeywords: ["SERVER", "TABLE", "GUEST", "CHECK #", "ORDER #", "DINE", "TO GO", "SEAT"],
                tipKeywordPrefixes: ["TIP", "GRATUITY"], fuelOnly: false)
        case .gas:
            return ReceiptProfile(
                extraSkipKeywords: ["PUMP", "GALLON", "PRICE/GAL", "PRICE PER", "UNLEADED", "REGULAR",
                                    "PREMIUM", "DIESEL", "GRADE", "AUTH"],
                tipKeywordPrefixes: [], fuelOnly: true)
        case .pharmacy:
            return ReceiptProfile(
                extraSkipKeywords: ["PRESCRIPTION", "NDC", "PHARMACY", "REFILL", "COPAY"],
                tipKeywordPrefixes: [], fuelOnly: false)
        case .retail:
            return ReceiptProfile(
                extraSkipKeywords: ["CASHIER", "REGISTER", "STORE #", "SKU"],
                tipKeywordPrefixes: [], fuelOnly: false)
        case .warehouse, .grocery, .generic, .auto:
            return .generic
        }
    }
}
