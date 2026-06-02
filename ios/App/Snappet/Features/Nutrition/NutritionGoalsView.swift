import SwiftUI

/// Goals tab — lets the user set daily calorie budget and macro targets.
struct NutritionGoalsView: View {
    var goal: NutritionGoal
    let onSave: (NutritionGoal) -> Void

    @State private var kcal: Double
    @State private var protein: Double
    @State private var carbs: Double
    @State private var fat: Double

    init(goal: NutritionGoal, onSave: @escaping (NutritionGoal) -> Void) {
        self.goal = goal
        self.onSave = onSave
        _kcal    = State(initialValue: goal.dailyKcal)
        _protein = State(initialValue: goal.proteinG)
        _carbs   = State(initialValue: goal.carbsG)
        _fat     = State(initialValue: goal.fatG)
    }

    var body: some View {
        Form {
            Section("Daily Target") {
                GoalSliderRow(label: "Calories", unit: "kcal", value: $kcal, range: 800...5000, step: 50)
            }
            Section("Macros") {
                GoalSliderRow(label: "Protein",      unit: "g", value: $protein, range: 10...400,  step: 5)
                GoalSliderRow(label: "Carbohydrates", unit: "g", value: $carbs,   range: 10...700,  step: 5)
                GoalSliderRow(label: "Fat",           unit: "g", value: $fat,     range: 10...300,  step: 5)
            }
            Section {
                Button("Save Goals") {
                    let updated = NutritionGoal(
                        dailyKcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat
                    )
                    onSave(updated)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("nutrition.saveGoals")
            }
        }
    }
}

private struct GoalSliderRow: View {
    let label: String; let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>; let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.xs) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value)) \(unit)").foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(SnappetColor.moduleAccent("nutrition"))
        }
    }
}
