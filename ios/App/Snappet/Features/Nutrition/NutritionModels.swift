import Foundation
import SwiftData

/// Which part of the day a food was logged under.
enum MealSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch:     return "Lunch"
        case .dinner:    return "Dinner"
        case .snack:     return "Snacks"
        }
    }
    var systemImage: String {
        switch self {
        case .breakfast: return "sunrise"
        case .lunch:     return "sun.max"
        case .dinner:    return "moon"
        case .snack:     return "carrot"
        }
    }
}

/// One logged food in the diary, persisted to the shared SnappetCore store. The integrator
/// appends `FoodLogEntry.self` to `SnappetSchema.models`.
///
/// Stored as a **denormalized snapshot** (the `TipCalculation` precedent in `decisions.md`):
/// each row carries the food's name/brand and its **per-serving** nutrients at the moment it
/// was logged, plus how many servings. Totals are derived (`perServing × quantity`). This
/// keeps the row self-describing and decoupled from the read-only bundled food catalog — the
/// catalog can be refreshed in an app update without rewriting history. `barcode`/`source`
/// are kept for provenance (catalog / custom / quick-add). Custom foods + a saved-goals model
/// are deferred to a later phase; Phase-1 goals live in `@AppStorage`.
@Model
final class FoodLogEntry {
    var id: UUID
    var name: String
    var brand: String?
    /// Persisted as the `MealSlot` raw value (string), like other suite enums.
    var mealRaw: String
    /// Human-readable serving the per-serving nutrients describe, e.g. "1 cup (240 g)".
    var servingDescription: String
    /// Number of servings logged.
    var quantity: Double

    // Per-serving nutrients (totals = these × quantity, via `ServingMath.scale`).
    var kcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double?
    var sugarG: Double?
    var sodiumG: Double?

    /// Barcode (GTIN/UPC) when the entry came from a scan, else `nil`.
    var barcode: String?
    /// Provenance: "catalog" | "custom" | "quick".
    var source: String
    var loggedAt: Date

    init(id: UUID = UUID(), name: String, brand: String? = nil, meal: MealSlot,
         servingDescription: String, quantity: Double, perServing: Nutrients,
         barcode: String? = nil, source: String = "catalog", loggedAt: Date = .now) {
        self.id = id
        self.name = name
        self.brand = brand
        self.mealRaw = meal.rawValue
        self.servingDescription = servingDescription
        self.quantity = quantity
        self.kcal = perServing.kcal
        self.proteinG = perServing.proteinG
        self.carbsG = perServing.carbsG
        self.fatG = perServing.fatG
        self.fiberG = perServing.fiberG
        self.sugarG = perServing.sugarG
        self.sodiumG = perServing.sodiumG
        self.barcode = barcode
        self.source = source
        self.loggedAt = loggedAt
    }

    var meal: MealSlot { MealSlot(rawValue: mealRaw) ?? .snack }

    /// The per-serving nutrients as a value type (for `ServingMath`).
    var perServing: Nutrients {
        Nutrients(kcal: kcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                  fiberG: fiberG, sugarG: sugarG, sodiumG: sodiumG)
    }

    /// The logged total (per-serving × quantity).
    var total: Nutrients { ServingMath.scale(perServing, by: quantity) }
}
</content>
