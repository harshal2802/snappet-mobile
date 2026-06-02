import SwiftUI

/// Sheet for searching the bundled food catalog and adding a food to a meal.
struct AddFoodView: View {
    let meal: MealSlot
    let onLog: (FoodLogEntry) -> Void

    @State private var query = ""
    @State private var results: [FoodItem] = []
    @State private var selectedItem: FoodItem? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty && query.isEmpty {
                    Section("Common Foods") {
                        ForEach(FoodCatalog.shared.seedData.prefix(10)) { item in
                            FoodResultRow(item: item) { selectedItem = item }
                        }
                    }
                } else {
                    Section(results.isEmpty ? "No results" : "Results") {
                        ForEach(results) { item in
                            FoodResultRow(item: item) { selectedItem = item }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search foods…")
            .onChange(of: query) { _, q in
                results = FoodCatalog.shared.search(query: q)
            }
            .navigationTitle("Add to \(meal.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $selectedItem) { item in
                FoodDetailView(item: item, meal: meal) { entry in
                    onLog(entry)
                    dismiss()
                }
            }
        }
    }
}

private struct FoodResultRow: View {
    let item: FoodItem
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline).foregroundStyle(.primary)
                    if let brand = item.brand {
                        Text(brand).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(item.kcalPer100g)) kcal").font(.caption.bold())
                    Text("per 100 g").font(.caption2).foregroundStyle(.tertiary)
                    if let ns = item.nutriScore {
                        NutriScoreBadge(grade: ns)
                    }
                }
            }
        }
        .accessibilityIdentifier("nutrition.foodResult")
    }
}

private struct NutriScoreBadge: View {
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
        Text(grade)
            .font(.caption2.bold())
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}
