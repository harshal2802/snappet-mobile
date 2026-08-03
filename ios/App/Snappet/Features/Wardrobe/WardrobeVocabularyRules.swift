import Foundation

// The PURE rules behind "add a custom value in any dropdown, and remember it for next time"
// (wardrobe prompt 05). No SwiftData here — the store applies these; the tests exercise them
// against the shapes the real closet actually contains.
//
// The measurement that dictated the normalization: of 95 non-empty `material` values on the real
// device, **41 carried stray leading/trailing whitespace**, so `'Lululemon '` (25 items) and
// `'Lululemon'` (5 items) were two separate values. 22 raw distinct collapsed to 19 normalized.
// Preventing that recurrence is this file's main job.

enum WardrobeVocabularyRules {

    /// Which dropdown a remembered value belongs to.
    enum Field: String, CaseIterable, Codable, Sendable, Identifiable {
        case category, color, pattern, style   // scored — custom values need a `mapsTo`
        case brand, size, material             // free text — nothing to score against

        var id: String { rawValue }

        var title: String {
            switch self {
            case .category: return "Category"
            case .color: return "Color"
            case .pattern: return "Pattern"
            case .style: return "Style"
            case .brand: return "Brand"
            case .size: return "Size"
            case .material: return "Material"
            }
        }

        /// Whether a custom value in this field must declare the built-in it behaves like.
        ///
        /// `OutfitComposer` scores color harmony over a closed 16-family wheel and formality over a
        /// 0–5 style scale. A free-string color has no hue and no formality, so without a mapping
        /// an item carrying one would silently drop out of every suggestion — the failure would be
        /// invisible, which is the worst kind. Brand/size/material feed no scoring, so they don't ask.
        var needsMapping: Bool {
            switch self {
            case .category, .color, .pattern, .style: return true
            case .brand, .size, .material: return false
            }
        }

        /// The built-in options offered as "behaves like" for a custom value.
        var builtInRaws: [String] {
            switch self {
            case .category: return GarmentCategory.allCases.map(\.rawValue)
            case .color: return GarmentColorFamily.allCases.map(\.rawValue)
            case .pattern: return GarmentPattern.allCases.map(\.rawValue)
            case .style: return GarmentStyle.allCases.map(\.rawValue)
            case .brand, .size, .material: return []
            }
        }
    }

    /// One row in a value picker.
    struct Choice: Equatable, Identifiable, Sendable {
        var value: String
        /// Empty for a built-in.
        var mapsToRaw: String
        var useCount: Int
        var isBuiltIn: Bool

        var id: String { value.lowercased() }
    }

    /// Trim and collapse inner runs of whitespace. The one function standing between the closet and
    /// another `'Uniqlo '`.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Whether two values are "the same value" for dedupe: normalized and case-insensitive, so
    /// `'Uniqlo '`, `'uniqlo'` and `'Uniqlo'` are one entry.
    static func isSameValue(_ a: String, _ b: String) -> Bool {
        normalize(a).caseInsensitiveCompare(normalize(b)) == .orderedSame
    }

    /// Fold a list of raw values into unique entries with counts, most-used first.
    ///
    /// The **first spelling encountered wins** as the display form, so folding preserves the user's
    /// own capitalization rather than imposing one. Ties break alphabetically, so the list is
    /// stable between launches instead of shuffling.
    static func fold(_ values: [String]) -> [(value: String, count: Int)] {
        var order: [String] = []            // normalized-lowercased keys, first-seen order
        var display: [String: String] = [:]
        var counts: [String: Int] = [:]
        for raw in values {
            let clean = normalize(raw)
            guard !clean.isEmpty else { continue }
            let key = clean.lowercased()
            if counts[key] == nil { order.append(key); display[key] = clean }
            counts[key, default: 0] += 1
        }
        return order
            .map { (display[$0] ?? $0, counts[$0] ?? 0) }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
                               : lhs.1 > rhs.1
            }
    }

    /// The picker's rows: the user's remembered values first (most used), then any built-ins they
    /// haven't already got a custom entry for. Built-ins keep their titles; customs keep the user's
    /// wording.
    static func choices(field: Field,
                        remembered: [(value: String, mapsToRaw: String, useCount: Int)],
                        builtInTitles: [(raw: String, title: String)]) -> [Choice] {
        let custom = remembered
            .sorted { $0.useCount == $1.useCount
                        ? $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
                        : $0.useCount > $1.useCount }
            .map { Choice(value: $0.value, mapsToRaw: $0.mapsToRaw,
                          useCount: $0.useCount, isBuiltIn: false) }
        let taken = Set(custom.map { normalize($0.value).lowercased() })
        let builtIns = builtInTitles
            .filter { !taken.contains(normalize($0.title).lowercased()) }
            .map { Choice(value: $0.title, mapsToRaw: $0.raw, useCount: 0, isBuiltIn: true) }
        return custom + builtIns
    }

    /// Validate a value the user is about to add. Returns the reason it can't be added, or nil.
    static func rejectionReason(for raw: String, field: Field, existing: [String]) -> String? {
        let clean = normalize(raw)
        if clean.isEmpty { return "Give it a name first." }
        if clean.count > 40 { return "That's too long for a \(field.title.lowercased())." }
        if existing.contains(where: { isSameValue($0, clean) }) {
            return "\(clean) is already in your list."
        }
        return nil
    }
}
