import Foundation

// How the closet groups and filters by category once categories can be CUSTOM (wardrobe prompt 05
// follow-up). Pure, so the ordering rule is testable without a store.
//
// The bug this exists to fix: `ClosetView` grouped by `GarmentCategory.allCases` and hard-coded its
// filter chips to six built-ins. A custom category is stored as a raw string that matches no enum
// case, so `item.category` resolved it through the scoring map to a *built-in* — meaning a garment
// filed under "Loungewear" silently appeared in the Tops section and had no chip of its own. The
// scoring fallback is right for the composer and wrong for wayfinding: display must follow what the
// user actually typed.

enum WardrobeClosetGrouping {

    /// One category as the closet shows it. `key` is the stored raw (a built-in raw like "top", or
    /// the user's own wording like "Loungewear") — the identity used for grouping and filtering.
    struct Category: Equatable, Identifiable, Sendable {
        var key: String
        /// Section header / chip label.
        var title: String
        var isBuiltIn: Bool

        var id: String { key }
    }

    /// The built-ins offered as quick filters even when the closet has none of them yet — the same
    /// six the chip strip has always shown.
    static let pinnedBuiltIns: [GarmentCategory] = [.top, .bottom, .shoes, .outerwear, .dress, .accessory]

    /// Display title for a stored raw: the built-in's plural for a known case, the user's wording
    /// verbatim otherwise. Custom values are NOT pluralized — guessing an English plural for an
    /// arbitrary user string produces "Loungewears".
    static func title(forKey key: String, plural: Bool) -> String {
        guard let builtIn = GarmentCategory(rawValue: key) else { return key }
        return plural ? builtIn.pluralTitle : builtIn.title
    }

    /// Every category present in the closet, ordered: built-ins in enum order first (so the
    /// familiar sections keep their familiar places), then customs alphabetically.
    static func present(in keys: [String], plural: Bool) -> [Category] {
        var seen = Set<String>()
        var builtIns: [Category] = []
        var customs: [Category] = []
        for key in keys where !key.isEmpty {
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let category = Category(key: key, title: title(forKey: key, plural: plural),
                                    isBuiltIn: GarmentCategory(rawValue: key) != nil)
            if category.isBuiltIn { builtIns.append(category) } else { customs.append(category) }
        }
        let order = GarmentCategory.allCases.map(\.rawValue)
        builtIns.sort { (order.firstIndex(of: $0.key) ?? 0) < (order.firstIndex(of: $1.key) ?? 0) }
        customs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return builtIns + customs
    }

    /// The filter chips: the pinned built-ins (always, even when empty — they're wayfinding, not a
    /// census) plus any CUSTOM category the closet actually contains. A custom chip that matched
    /// nothing would be noise, which is why customs are present-only.
    static func filterChips(presentKeys: [String]) -> [Category] {
        let pinned = pinnedBuiltIns.map {
            Category(key: $0.rawValue, title: $0.pluralTitle, isBuiltIn: true)
        }
        let pinnedKeys = Set(pinned.map(\.key))
        let extras = present(in: presentKeys, plural: true)
            .filter { !$0.isBuiltIn || !pinnedKeys.contains($0.key) }
        return pinned + extras
    }
}
