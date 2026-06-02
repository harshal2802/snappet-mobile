import Foundation

/// Macro distribution. Pure value type.
struct MacroSplit {
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    var kcalFromProtein: Double { proteinG * 4 }
    var kcalFromCarbs: Double   { carbsG * 4 }
    var kcalFromFat: Double     { fatG * 9 }
    var totalKcal: Double       { kcalFromProtein + kcalFromCarbs + kcalFromFat }

    enum Macro { case protein, carbs, fat }

    func fraction(of macro: Macro) -> Double {
        guard totalKcal > 0 else { return 0 }
        switch macro {
        case .protein: return kcalFromProtein / totalKcal
        case .carbs:   return kcalFromCarbs   / totalKcal
        case .fat:     return kcalFromFat     / totalKcal
        }
    }
}
