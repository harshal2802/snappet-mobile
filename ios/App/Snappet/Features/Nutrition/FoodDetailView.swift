import SwiftUI

/// Detail view for a food item — shows nutrition facts and lets the user pick a serving
/// size + quantity before adding to the diary.
struct FoodDetailView: View {
    let item: FoodItem
    let meal: MealSlot
    let onAdd: (FoodLogEntry) -> Void

    @State private var servingGrams: Double
    @State private var quantity: Double = 1.0
    @Environment(\.dismiss) private var dismiss

    init(item: FoodItem, meal: MealSlot, onAdd: @escaping (FoodLogEntry) -> Void) {
        self.item = item
        self.meal = meal
        self.onAdd = onAdd
        _servingGrams = State(initialValue: item.servingSize > 0 ? item.servingSize : 100)
    }

    private var math: ServingMath {
        ServingMath(item: item, servingGrams: servingGrams, quantity: quantity)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SnappetSpacing.xl) {
                    VStack(alignment: .leading, spacing: SnappetSpacing.xs) {
                        Text(item.name).font(.title2.bold())
                        if let brand = item.brand {
                            Text(brand).font(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack(spacing: SnappetSpacing.sm) {
                            Text(item.dataSource == "OFF" ? "Open Food Facts" : "USDA FDC")
                                .font(.caption2).foregroundStyle(.tertiary)
                            if let ns = item.nutriScore {
                                NutriScoreBadgeDetail(grade: ns)
                            }
                        }
                    }

                    // Serving controls
                    VStack(alignment: .leading, spacing: SnappetSpacing.md) {
                        Text("Serving size").font(.headline)
                        HStack {
                            Text(item.servingLabel).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(servingGrams)) g")
                                .font(.subheadline.monospacedDigit())
                        }
                        Slider(value: $servingGrams, in: 5...500, step: 5)
                            .tint(SnappetColor.moduleAccent("nutrition"))

                        HStack {
                            Text("Quantity").font(.subheadline)
                            Spacer()
                            Stepper(value: $quantity, in: 0.25...10, step: 0.25) {
                                Text(quantity.formatted(.number.precision(.fractionLength(0...2))))
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                    .padding(SnappetSpacing.lg)
                    .snappetCard()

                    // Computed totals
                    VStack(alignment: .leading, spacing: SnappetSpacing.md) {
                        Text("Totals").font(.headline)
                        NutrientRow(label: "Calories",   value: math.kcal,     unit: "kcal", bold: true)
                        NutrientRow(label: "Protein",    value: math.proteinG, unit: "g")
                        NutrientRow(label: "Carbs",      value: math.carbsG,   unit: "g")
                        NutrientRow(label: "Fat",        value: math.fatG,     unit: "g")
                        Divider()
                        NutrientRow(label: "Per 100 g",  value: item.kcalPer100g, unit: "kcal")
                    }
                    .padding(SnappetSpacing.lg)
                    .snappetCard()

                    Button {
                        let entry = FoodLogEntry(
                            foodRef: item.id,
                            foodName: item.name,
                            meal: meal,
                            servings: quantity,
                            servingGrams: servingGrams,
                            kcal: math.kcal,
                            proteinG: math.proteinG,
                            carbsG: math.carbsG,
                            fatG: math.fatG
                        )
                        onAdd(entry)
                    } label: {
                        Label("Add to \(meal.rawValue)", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SnappetColor.moduleAccent("nutrition"))
                    .accessibilityIdentifier("nutrition.addToDiary")
                }
                .padding(SnappetSpacing.lg)
            }
            .navigationTitle("Food Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct NutrientRow: View {
    let label: String; let value: Double; let unit: String; var bold: Bool = false
    var body: some View {
        HStack {
            Text(label).font(bold ? .subheadline.bold() : .subheadline)
            Spacer()
            Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                .font(bold ? .subheadline.bold().monospacedDigit() : .subheadline.monospacedDigit())
        }
    }
}

private struct NutriScoreBadgeDetail: View {
    let grade: String
    private var color: Color {
        switch grade {
        case "A": return .green
        case "B": return Color(hex: 0x85BB2F)
        case "C": return .yellow
        case "D": return .orange
        default:  return .red
        }
    }
    var body: some View {
        Text("Nutri-Score \(grade)")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}
