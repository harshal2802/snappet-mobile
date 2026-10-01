import Foundation

/// Exact weight entry (prompt 139, wireframe frames 15–16). Weights used to move only in fixed ±2.5
/// steps with no way to type — so 71.3 kg or a 1.25 kg microplate jump couldn't be logged. Now a weight
/// can be typed exactly, and the ± step is a per-unit setting. Pure (Foundation only) → unit-tested.
enum WeightEntry {
    static let maxWeight = 2000.0

    /// `@AppStorage` key for the ± step of `unit` (0 = the unit's default).
    static func stepKey(for unit: WeightUnit) -> String { "workout.weightStep.\(unit.rawValue)" }

    static func stepChoices(for unit: WeightUnit) -> [Double] {
        unit == .lb ? [1, 2.5, 5, 10] : [0.5, 1, 1.25, 2.5, 5]
    }

    /// Today's behaviour stays the default: 2.5 kg / 5 lb.
    static func defaultStep(for unit: WeightUnit) -> Double { unit == .lb ? 5 : 2.5 }

    /// The step to use from a stored value — anything unset or not offered for this unit falls back.
    static func step(stored: Double, unit: WeightUnit) -> Double {
        stepChoices(for: unit).contains(stored) ? stored : defaultStep(for: unit)
    }

    /// `value` moved by `delta` from wherever it is (never snapped to a step grid), clamped to
    /// 0…max and rounded to 0.01 so repeated float adds don't print 71.30000001.
    static func nudge(_ value: Double, by delta: Double) -> Double {
        let next = min(maxWeight, max(0, value + delta))
        return (next * 100).rounded() / 100
    }

    /// Parse typed text. Accepts the locale's decimal separator or either of "." / ",". Returns nil for
    /// anything that isn't a number in 0…max (the field then keeps the previous value).
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard normalized.filter({ $0 == "." }).count <= 1,
              normalized.allSatisfy({ $0.isNumber || $0 == "." }),
              let v = Double(normalized), v.isFinite, v >= 0, v <= maxWeight else { return nil }
        return (v * 100).rounded() / 100
    }

    /// The text a field starts with when editing begins: empty for bodyweight, else the plain number.
    static func editText(_ value: Double) -> String {
        value <= 0 ? "" : SetMeasure.formatWeight(value)
    }
}
