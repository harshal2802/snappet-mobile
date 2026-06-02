import SwiftUI
import SwiftData

/// Food detail: pick a serving + quantity, see the computed totals, and add it to the diary.
/// Persists a `FoodLogEntry` (denormalized snapshot), logs usage to SnappetCore, and writes
/// the meal to HealthKit best-effort (a no-op/clean failure on the simulator).
struct FoodDetailView: View {
    let item: FoodItem
    let meal: MealSlot
    /// Called after a successful log so the parent sheet can dismiss.
    let onLogged: () -> Void

    @Environment(SnappetCore.self) private var core
    @Environment(\.modelContext) private var modelContext

    @State private var serving: FoodServing
    @State private var quantity: Double = 1

    private let health: NutritionHealthWriting = NutritionHealthService()

    init(item: FoodItem, meal: MealSlot, onLogged: @escaping () -> Void) {
        self.item = item
        self.meal = meal
        self.onLogged = onLogged
        _serving = State(initialValue: item.defaultServing
            ?? FoodServing(description: "1 serving", nutrients: .zero))
    }

    private var total: Nutrients { ServingMath.scale(serving.nutrients, by: quantity) }

    var body: some View {
        Form {
            if item.servings.count > 1 {
                Section("Serving") {
                    Picker("Serving", selection: $serving) {
                        ForEach(item.servings) { Text($0.description).tag($0) }
                    }
                    .accessibilityIdentifier("nutrition.detail.serving")
                }
            }
            Section("Quantity") {
                Stepper(value: $quantity, in: 0.5...20, step: 0.5) {
                    HStack {
                        Text("Servings")
                        Spacer()
                        Text(quantity.formatted(.number.precision(.fractionLength(0...1))))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityIdentifier("nutrition.detail.quantity")
            }
            Section("Nutrition (this amount)") {
                nutrientRow("Calories", value: total.kcal, unit: "kcal")
                nutrientRow("Protein", value: total.proteinG, unit: "g")
                nutrientRow("Carbs", value: total.carbsG, unit: "g")
                nutrientRow("Fat", value: total.fatG, unit: "g")
                if let fiber = total.fiberG { nutrientRow("Fiber", value: fiber, unit: "g") }
                if let sugar = total.sugarG { nutrientRow("Sugar", value: sugar, unit: "g") }
                if let sodium = total.sodiumG { nutrientRow("Sodium", value: sodium * 1000, unit: "mg") }
            }
            Section {
                Text("Nutrition data from Open Food Facts (ODbL) & USDA FoodData Central. May be inaccurate.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { log() }.accessibilityIdentifier("nutrition.detail.add")
            }
        }
    }

    private func nutrientRow(_ label: String, value: Double, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Int(value.rounded())) \(unit)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func log() {
        let entry = FoodLogEntry(
            name: item.name, brand: item.brand, meal: meal,
            servingDescription: serving.description, quantity: quantity,
            perServing: serving.nutrients, barcode: item.barcode,
            source: item.barcode == nil ? "catalog" : "scan"
        )
        modelContext.insert(entry)
        try? modelContext.save()

        core.log(module: "nutrition", action: "logged-food",
                 summary: "\(item.name) · \(meal.title)", metric: total.kcal)

        // Best-effort HealthKit write — clean no-op on the simulator (device-only).
        let writer = health
        let name = item.name
        let totals = total
        Task.detached {
            try? await writer.saveMeal(name: name, nutrients: totals, date: .now)
        }
        onLogged()
    }
}
</content>
