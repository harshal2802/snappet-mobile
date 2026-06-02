import SwiftUI
import SwiftData

/// Route value for the Nutrition mini-app's pushed History screen.
struct NutritionHistoryRoute: Hashable {}

/// Calorie & Nutrition — the diary home. Shows today's calorie-budget ring, macro bars and
/// per-meal lists, with an Add-food sheet and a pushed History screen. Logs usage to
/// SnappetCore (Home dashboard) and persists each logged food as a `FoodLogEntry`.
///
/// Pushed into the App Library's NavigationStack — owns no NavigationStack of its own. The
/// Add-food / food-detail flow is a sheet (which may carry its own stack); History pushes
/// onto the shared `SuiteRouter` path.
struct NutritionRootView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    /// All logged foods, newest first; filtered to "today" in code (Phase-1 diary scope).
    @Query(sort: \FoodLogEntry.loggedAt, order: .reverse) private var allEntries: [FoodLogEntry]

    /// Phase-1 goals live in `@AppStorage` (a saved-goals `@Model` is a later phase).
    @AppStorage("nutrition.targetKcal") private var targetKcal: Double = 2000
    @AppStorage("nutrition.targetProteinG") private var targetProteinG: Double = 100
    @AppStorage("nutrition.targetCarbsG") private var targetCarbsG: Double = 250
    @AppStorage("nutrition.targetFatG") private var targetFatG: Double = 65

    @State private var addingToMeal: MealSlot?
    @State private var editingGoals = false

    private var todayEntries: [FoodLogEntry] {
        let start = Calendar.current.startOfDay(for: .now)
        return allEntries.filter { $0.loggedAt >= start }
    }

    private var todayTotal: Nutrients { ServingMath.total(todayEntries.map(\.total)) }
    private var budget: NutritionBudget {
        NutritionBudget(targetKcal: targetKcal, consumedKcal: todayTotal.kcal)
    }

    var body: some View {
        List {
            summarySection
            ForEach(MealSlot.allCases) { meal in
                mealSection(meal)
            }
        }
        .navigationTitle("Nutrition")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { router.push(NutritionHistoryRoute()) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("nutrition.history")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { editingGoals = true } label: {
                    Label("Goals", systemImage: "target")
                }
                .accessibilityIdentifier("nutrition.goals")
            }
        }
        .navigationDestination(for: NutritionHistoryRoute.self) { _ in
            NutritionHistoryView()
        }
        .sheet(item: $addingToMeal) { meal in
            AddFoodView(meal: meal)
        }
        .sheet(isPresented: $editingGoals) {
            NutritionGoalsEditor(targetKcal: $targetKcal, proteinG: $targetProteinG,
                                 carbsG: $targetCarbsG, fatG: $targetFatG)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            CalorieRing(budget: budget)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SnappetSpacing.sm)
                .accessibilityIdentifier("nutrition.calorieRing")
            MacroBars(consumed: MacroSplit(todayTotal),
                      targetProteinG: targetProteinG, targetCarbsG: targetCarbsG, targetFatG: targetFatG)
        } header: {
            Text("Today")
        }
    }

    private func mealSection(_ meal: MealSlot) -> some View {
        let entries = todayEntries.filter { $0.meal == meal }
        let kcal = entries.reduce(0) { $0 + $1.total.kcal }
        return Section {
            ForEach(entries) { entry in
                FoodLogRow(entry: entry)
            }
            .onDelete { offsets in delete(offsets, in: entries) }
            Button {
                addingToMeal = meal
            } label: {
                Label("Add food", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("nutrition.add.\(meal.rawValue)")
        } header: {
            HStack {
                Label(meal.title, systemImage: meal.systemImage)
                Spacer()
                Text("\(Int(kcal)) kcal").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func delete(_ offsets: IndexSet, in entries: [FoodLogEntry]) {
        for index in offsets { modelContext.delete(entries[index]) }
        try? modelContext.save()
    }
}

/// A circular calorie-budget ring: consumed vs. (burn-adjusted) target, with remaining in the
/// center. Pure presentation over the precomputed `NutritionBudget`.
private struct CalorieRing: View {
    let budget: NutritionBudget

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: budget.progress)
                .stroke(budget.isOverBudget ? AnyShapeStyle(.red) : AnyShapeStyle(.tint),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: budget.progress)
            VStack(spacing: 2) {
                Text("\(Int(budget.remainingKcal))")
                    .font(.system(.title, design: .rounded)).fontWeight(.bold)
                    .monospacedDigit().contentTransition(.numericText())
                Text(budget.isOverBudget ? "over" : "remaining")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(Int(budget.consumedKcal)) / \(Int(budget.targetKcal)) kcal")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(width: 150, height: 150)
    }
}

/// Three macro progress bars (protein/carb/fat) vs. their gram targets.
private struct MacroBars: View {
    let consumed: MacroSplit
    let targetProteinG: Double
    let targetCarbsG: Double
    let targetFatG: Double

    var body: some View {
        VStack(spacing: SnappetSpacing.sm) {
            bar("Protein", value: consumed.proteinG, target: targetProteinG)
            bar("Carbs", value: consumed.carbsG, target: targetCarbsG)
            bar("Fat", value: consumed.fatG, target: targetFatG)
        }
    }

    private func bar(_ label: String, value: Double, target: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(value)) / \(Int(target)) g")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: target > 0 ? min(1, value / target) : 0)
        }
    }
}

/// One logged-food row: name/brand + serving × quantity, with its calorie total.
private struct FoodLogRow: View {
    let entry: FoodLogEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text("\(entry.quantity.formatted(.number.precision(.fractionLength(0...1)))) × \(entry.servingDescription)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(entry.total.kcal)) kcal").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// A small sheet to set Phase-1 daily goals (calories + macro grams).
private struct NutritionGoalsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var targetKcal: Double
    @Binding var proteinG: Double
    @Binding var carbsG: Double
    @Binding var fatG: Double

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily target") {
                    stepper("Calories", value: $targetKcal, range: 1000...5000, step: 50, unit: "kcal")
                }
                Section("Macros") {
                    stepper("Protein", value: $proteinG, range: 0...400, step: 5, unit: "g")
                    stepper("Carbs", value: $carbsG, range: 0...600, step: 5, unit: "g")
                    stepper("Fat", value: $fatG, range: 0...300, step: 5, unit: "g")
                }
            }
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("nutrition.goals.done")
                }
            }
        }
    }

    private func stepper(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                         step: Double, unit: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
</content>
