import Foundation

/// Calorie budget state for today. Pure value type — no device imports.
struct NutritionBudget {
    let consumed: Double
    let goal: Double
    let activeBurned: Double

    var remaining: Double { goal - consumed }
    var net: Double { consumed - activeBurned }
    var ringFraction: Double { min(max(consumed / max(goal, 1), 0), 1) }

    /// Mifflin–St Jeor BMR fallback when HealthKit energy is unavailable.
    static func mifflinBMR(weightKg: Double, heightCm: Double, ageYears: Int, isMale: Bool) -> Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears)
        return isMale ? base + 5 : base - 161
    }
}
