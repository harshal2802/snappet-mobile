import Foundation

/// A serving option for a food (label + the grams/ml it represents), with the nutrients
/// for that one serving.
struct FoodServing: Equatable, Sendable, Identifiable, Hashable {
    var id: String { description }
    /// e.g. "1 cup (240 g)", "100 g", "1 bar (45 g)".
    let description: String
    let nutrients: Nutrients

    // Hashable/Equatable on the description is enough for picker identity.
    static func == (lhs: FoodServing, rhs: FoodServing) -> Bool { lhs.description == rhs.description }
    func hash(into hasher: inout Hasher) { hasher.combine(description) }
}

/// A food the user can log — from the bundled read-only catalog (Open Food Facts branded +
/// USDA FoodData Central generic), a barcode scan, or a custom entry. A plain value type so
/// the catalog reader, search and UI stay decoupled from any storage engine.
struct FoodItem: Equatable, Sendable, Identifiable, Hashable {
    let id: String          // catalog row id, GTIN, or a generated id for custom foods
    let name: String
    let brand: String?
    let barcode: String?    // GTIN/UPC when present
    /// One or more serving options; the first is the default selection.
    let servings: [FoodServing]
    /// Open Food Facts Nutri-Score grade (a…e), when available.
    let nutriScore: String?
    /// Open Food Facts NOVA processing group (1…4), when available.
    let novaGroup: Int?

    var defaultServing: FoodServing? { servings.first }
}

/// Read-only food lookup. Implemented in Phase 1 by `SampleFoodCatalog`; the production
/// implementation (a `BundledFoodCatalog` reading the trimmed `food.sqlite3` shipped under
/// `Resources/`, built dev-time by `tools/build-food-db/`) is a follow-up — kept behind this
/// protocol so the views and view models don't change when it lands.
protocol FoodCatalog: Sendable {
    /// Name search (case-insensitive substring). Returns at most `limit` items.
    func search(_ query: String, limit: Int) async -> [FoodItem]
    /// Exact barcode (GTIN/UPC) lookup; `nil` when the catalog has no such product.
    func lookup(barcode: String) async -> FoodItem?
}

/// A tiny in-memory catalog so the mini-app is fully usable before the bundled DB asset
/// exists (the asset is multi-GB and built dev-time — see `tools/build-food-db/README.md`).
/// Real coverage comes from `BundledFoodCatalog` reading `food.sqlite3`.
struct SampleFoodCatalog: FoodCatalog {
    static let sample: [FoodItem] = [
        FoodItem(id: "fdc-banana", name: "Banana, raw", brand: nil, barcode: nil,
                 servings: [FoodServing(description: "1 medium (118 g)",
                                        nutrients: Nutrients(kcal: 105, proteinG: 1.3, carbsG: 27, fatG: 0.4,
                                                             fiberG: 3.1, sugarG: 14.4, sodiumG: 0.001)),
                            FoodServing(description: "100 g",
                                        nutrients: Nutrients(kcal: 89, proteinG: 1.1, carbsG: 23, fatG: 0.3,
                                                             fiberG: 2.6, sugarG: 12.2, sodiumG: 0.001))],
                 nutriScore: "a", novaGroup: 1),
        FoodItem(id: "fdc-chicken-breast", name: "Chicken breast, grilled", brand: nil, barcode: nil,
                 servings: [FoodServing(description: "100 g",
                                        nutrients: Nutrients(kcal: 165, proteinG: 31, carbsG: 0, fatG: 3.6,
                                                             fiberG: 0, sugarG: 0, sodiumG: 0.074))],
                 nutriScore: nil, novaGroup: 1),
        FoodItem(id: "fdc-oats", name: "Rolled oats, dry", brand: nil, barcode: nil,
                 servings: [FoodServing(description: "1/2 cup (40 g)",
                                        nutrients: Nutrients(kcal: 150, proteinG: 5, carbsG: 27, fatG: 3,
                                                             fiberG: 4, sugarG: 1, sodiumG: 0))],
                 nutriScore: "a", novaGroup: 1),
        FoodItem(id: "off-3017620422003", name: "Nutella", brand: "Ferrero", barcode: "3017620422003",
                 servings: [FoodServing(description: "1 tbsp (15 g)",
                                        nutrients: Nutrients(kcal: 80, proteinG: 0.9, carbsG: 8.7, fatG: 4.5,
                                                             fiberG: nil, sugarG: 8.2, sodiumG: 0.0066))],
                 nutriScore: "e", novaGroup: 4),
        FoodItem(id: "off-greek-yogurt", name: "Greek yogurt, plain", brand: nil, barcode: nil,
                 servings: [FoodServing(description: "1 container (170 g)",
                                        nutrients: Nutrients(kcal: 100, proteinG: 17, carbsG: 6, fatG: 0.7,
                                                             fiberG: 0, sugarG: 4, sodiumG: 0.061))],
                 nutriScore: "b", novaGroup: 1),
        FoodItem(id: "fdc-egg", name: "Egg, large, whole", brand: nil, barcode: nil,
                 servings: [FoodServing(description: "1 large (50 g)",
                                        nutrients: Nutrients(kcal: 72, proteinG: 6.3, carbsG: 0.4, fatG: 4.8,
                                                             fiberG: 0, sugarG: 0.2, sodiumG: 0.071))],
                 nutriScore: nil, novaGroup: 1),
    ]

    func search(_ query: String, limit: Int) async -> [FoodItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return Self.sample
            .filter { $0.name.lowercased().contains(q) || ($0.brand?.lowercased().contains(q) ?? false) }
            .prefix(limit)
            .map { $0 }
    }

    func lookup(barcode: String) async -> FoodItem? {
        Self.sample.first { $0.barcode == barcode }
    }
}
</content>
