import SwiftUI
import SwiftData

/// Add-food sheet: search the bundled catalog and pick an item to log to `meal`. Owns its own
/// `NavigationStack` (it's a sheet), and pushes `FoodDetailView` to choose serving + quantity.
/// Barcode scanning is a Phase-2 entry point on this screen.
struct AddFoodView: View {
    let meal: MealSlot

    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var results: [FoodItem] = []

    /// Phase-1 catalog. Swapped for `BundledFoodCatalog` when the `food.sqlite3` asset lands.
    private let catalog: FoodCatalog = SampleFoodCatalog()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Search foods" : "No matches",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty
                            ? "Search the food database, or scan a barcode (coming soon)."
                            : "Try a different term, or add a custom food.")
                    )
                } else {
                    ForEach(results) { item in
                        Button { path.append(item) } label: { FoodResultRow(item: item) }
                            .accessibilityIdentifier("nutrition.result.\(item.id)")
                    }
                }
            }
            .navigationTitle("Add to \(meal.title)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search foods")
            .task(id: query) { results = await catalog.search(query, limit: 30) }
            .navigationDestination(for: FoodItem.self) { item in
                FoodDetailView(item: item, meal: meal) { dismiss() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// One search-result row: name/brand + a Nutri-Score badge + the default serving's calories.
private struct FoodResultRow: View {
    let item: FoodItem
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let brand = item.brand {
                    Text(brand).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let grade = item.nutriScore {
                Text(grade.uppercased())
                    .font(.caption2).bold().padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            if let kcal = item.defaultServing?.nutrients.kcal {
                Text("\(Int(kcal)) kcal").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
</content>
