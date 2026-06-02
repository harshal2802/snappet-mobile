import Foundation
import SwiftData

enum MealSlot: String, Codable, CaseIterable {
    case breakfast = "Breakfast"
    case lunch     = "Lunch"
    case dinner    = "Dinner"
    case snack     = "Snacks"
}

/// A food item from the bundled catalog (Open Food Facts or USDA FDC).
/// Not a SwiftData model — read-only reference data from `food.sqlite3`.
struct FoodItem: Identifiable, Hashable {
    var id: String
    var name: String
    var brand: String?
    var kcalPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double
    var servingSize: Double
    var servingLabel: String
    var nutriScore: String?
    var dataSource: String
}

/// One food logged to a meal. Persisted in SnappetCore.
@Model
final class FoodLogEntry {
    var id: UUID
    var foodRef: String
    var foodName: String
    var meal: String
    var servings: Double
    var servingGrams: Double
    var kcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var loggedAt: Date

    init(id: UUID = UUID(), foodRef: String, foodName: String, meal: MealSlot,
         servings: Double, servingGrams: Double, kcal: Double,
         proteinG: Double, carbsG: Double, fatG: Double, loggedAt: Date = .now) {
        self.id = id
        self.foodRef = foodRef
        self.foodName = foodName
        self.meal = meal.rawValue
        self.servings = servings
        self.servingGrams = servingGrams
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.loggedAt = loggedAt
    }

    var mealSlot: MealSlot { MealSlot(rawValue: meal) ?? .snack }
}

/// A user-created food not in the bundled catalog.
@Model
final class CustomFood {
    var id: UUID
    var name: String
    var kcalPer100g: Double
    var proteinPer100g: Double
    var carbsPer100g: Double
    var fatPer100g: Double
    var servingGrams: Double
    var createdAt: Date

    init(id: UUID = UUID(), name: String, kcalPer100g: Double, proteinPer100g: Double,
         carbsPer100g: Double, fatPer100g: Double, servingGrams: Double = 100, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.kcalPer100g = kcalPer100g
        self.proteinPer100g = proteinPer100g
        self.carbsPer100g = carbsPer100g
        self.fatPer100g = fatPer100g
        self.servingGrams = servingGrams
        self.createdAt = createdAt
    }
}

/// Daily nutrition goal.
@Model
final class NutritionGoal {
    var id: UUID
    var dailyKcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var updatedAt: Date

    init(id: UUID = UUID(), dailyKcal: Double = 2000, proteinG: Double = 150,
         carbsG: Double = 250, fatG: Double = 65, updatedAt: Date = .now) {
        self.id = id
        self.dailyKcal = dailyKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.updatedAt = updatedAt
    }
}
