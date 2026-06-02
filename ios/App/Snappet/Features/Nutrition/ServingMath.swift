import Foundation

/// Scales per-100g nutrition values to a given serving × quantity. Pure value type.
struct ServingMath {
    let kcalPer100g: Double
    let proteinPer100g: Double
    let carbsPer100g: Double
    let fatPer100g: Double
    let servingGrams: Double
    let quantity: Double

    var totalGrams: Double { servingGrams * quantity }
    var kcal: Double       { kcalPer100g    * totalGrams / 100 }
    var proteinG: Double   { proteinPer100g * totalGrams / 100 }
    var carbsG: Double     { carbsPer100g   * totalGrams / 100 }
    var fatG: Double       { fatPer100g     * totalGrams / 100 }

    init(item: FoodItem, servingGrams: Double, quantity: Double) {
        kcalPer100g    = item.kcalPer100g
        proteinPer100g = item.proteinPer100g
        carbsPer100g   = item.carbsPer100g
        fatPer100g     = item.fatPer100g
        self.servingGrams = servingGrams
        self.quantity     = quantity
    }

    init(kcalPer100g: Double, proteinPer100g: Double, carbsPer100g: Double, fatPer100g: Double,
         servingGrams: Double, quantity: Double) {
        self.kcalPer100g    = kcalPer100g
        self.proteinPer100g = proteinPer100g
        self.carbsPer100g   = carbsPer100g
        self.fatPer100g     = fatPer100g
        self.servingGrams   = servingGrams
        self.quantity       = quantity
    }
}
