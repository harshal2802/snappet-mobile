import Foundation

/// Pure, device-free nutrition math for the Calorie & Nutrition mini-app.
///
/// Everything here is value types with **no SwiftData / HealthKit / SwiftUI**, so the
/// serving arithmetic, macro split and calorie-budget logic are unit-testable in
/// `SnappetTests` with no device or simulator — the same discipline that keeps
/// `HighlightEngine` platform-free. The views and the SwiftData/HealthKit edges read
/// precomputed values from these types; they do no nutrition math themselves.

/// A nutrient bundle for one serving (or a scaled total). Energy in kcal, masses in grams.
/// Optional micronutrients are `nil` when the source data didn't provide them.
struct Nutrients: Equatable, Sendable, Codable {
    var kcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fiberG: Double?
    var sugarG: Double?
    /// Sodium stored in grams (HealthKit's canonical unit); display as mg.
    var sodiumG: Double?

    init(kcal: Double, proteinG: Double, carbsG: Double, fatG: Double,
         fiberG: Double? = nil, sugarG: Double? = nil, sodiumG: Double? = nil) {
        self.kcal = kcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.sugarG = sugarG
        self.sodiumG = sodiumG
    }

    static let zero = Nutrients(kcal: 0, proteinG: 0, carbsG: 0, fatG: 0)
}

/// Scaling and aggregation over `Nutrients`.
enum ServingMath {
    /// Scale a single serving's nutrients by a (non-negative) quantity of servings.
    /// A negative or non-finite quantity clamps to 0 so a bad input can't poison totals.
    static func scale(_ n: Nutrients, by quantity: Double) -> Nutrients {
        let q = (quantity.isFinite && quantity > 0) ? quantity : 0
        return Nutrients(
            kcal: n.kcal * q,
            proteinG: n.proteinG * q,
            carbsG: n.carbsG * q,
            fatG: n.fatG * q,
            fiberG: n.fiberG.map { $0 * q },
            sugarG: n.sugarG.map { $0 * q },
            sodiumG: n.sodiumG.map { $0 * q }
        )
    }

    /// Sum a list of already-scaled nutrient totals (e.g. a day's logged entries).
    /// Optional micronutrients sum only over the entries that provide them; the result
    /// is `nil` only when no entry provided that nutrient.
    static func total(_ items: [Nutrients]) -> Nutrients {
        items.reduce(Nutrients.zero) { acc, n in
            Nutrients(
                kcal: acc.kcal + n.kcal,
                proteinG: acc.proteinG + n.proteinG,
                carbsG: acc.carbsG + n.carbsG,
                fatG: acc.fatG + n.fatG,
                fiberG: addOptional(acc.fiberG, n.fiberG),
                sugarG: addOptional(acc.sugarG, n.sugarG),
                sodiumG: addOptional(acc.sodiumG, n.sodiumG)
            )
        }
    }

    private static func addOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        default: return (a ?? 0) + (b ?? 0)
        }
    }
}

/// The protein/carb/fat breakdown of a day, as grams and as a share of energy.
/// Uses the Atwater factors (4/4/9 kcal per gram) for the energy split.
struct MacroSplit: Equatable, Sendable {
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    var proteinKcal: Double { proteinG * 4 }
    var carbsKcal: Double { carbsG * 4 }
    var fatKcal: Double { fatG * 9 }
    var totalMacroKcal: Double { proteinKcal + carbsKcal + fatKcal }

    /// Fraction of macro-energy from protein/carb/fat (each 0...1). All zero when there's
    /// no macro energy yet, so a fresh day renders an empty—not NaN—bar.
    var fractions: (protein: Double, carbs: Double, fat: Double) {
        let total = totalMacroKcal
        guard total > 0 else { return (0, 0, 0) }
        return (proteinKcal / total, carbsKcal / total, fatKcal / total)
    }

    init(proteinG: Double, carbsG: Double, fatG: Double) {
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    init(_ n: Nutrients) {
        self.init(proteinG: n.proteinG, carbsG: n.carbsG, fatG: n.fatG)
    }
}

/// The day's calorie budget: target vs. consumed, optionally net of energy burned.
///
/// The net-calorie model is `net = consumed − (basal + active)` (a convention, not a
/// platform API). In Phase 1 `activeEnergyBurned`/`basalEnergyBurned` are `nil` (no
/// HealthKit read yet) and the budget is simply `target − consumed`; Phase 2 passes the
/// HealthKit-aggregated energy so the ring reflects calories burned too.
struct NutritionBudget: Equatable, Sendable {
    /// Daily calorie goal (kcal).
    let targetKcal: Double
    /// Calories consumed so far today (sum of logged entries).
    let consumedKcal: Double
    /// Active energy burned today from HealthKit (kcal), if available.
    let activeKcal: Double?
    /// Basal/resting energy burned today from HealthKit (kcal), if available.
    let basalKcal: Double?

    init(targetKcal: Double, consumedKcal: Double,
         activeKcal: Double? = nil, basalKcal: Double? = nil) {
        self.targetKcal = targetKcal
        self.consumedKcal = consumedKcal
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
    }

    /// Total energy expenditure if any burn data is present, else `nil`.
    var burnedKcal: Double? {
        guard activeKcal != nil || basalKcal != nil else { return nil }
        return (activeKcal ?? 0) + (basalKcal ?? 0)
    }

    /// Calories remaining against the target. When burn data is present this adds it back
    /// (eat-back model): remaining = target − consumed + burned.
    var remainingKcal: Double {
        targetKcal - consumedKcal + (burnedKcal ?? 0)
    }

    /// Progress 0...1 of consumed against the (burn-adjusted) target, clamped so the ring
    /// never exceeds a full turn even when the user goes over budget.
    var progress: Double {
        let adjustedTarget = targetKcal + (burnedKcal ?? 0)
        guard adjustedTarget > 0 else { return 0 }
        return min(1, max(0, consumedKcal / adjustedTarget))
    }

    var isOverBudget: Bool { remainingKcal < 0 }
}

/// Biological sex for the BMR estimate (the only place it's used).
enum BiologicalSex: String, Codable, Sendable, CaseIterable {
    case female, male
}

/// Basal metabolic rate via the Mifflin–St Jeor equation — used when HealthKit's
/// `basalEnergyBurned` is unavailable (often sparse). Pure so it's unit-tested.
///
///   BMR = 10·kg + 6.25·cm − 5·age + s,  where s = +5 (male) / −161 (female).
enum BasalEnergy {
    static func mifflinStJeor(weightKg: Double, heightCm: Double,
                              ageYears: Double, sex: BiologicalSex) -> Double {
        let s = (sex == .male) ? 5.0 : -161.0
        let bmr = 10 * weightKg + 6.25 * heightCm - 5 * ageYears + s
        return max(0, bmr)
    }
}
</content>
