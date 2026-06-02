import SwiftUI
import SwiftData
import Charts

/// Root view for the Nutrition mini-app. Provides three tabs: Today diary, History, and Goals.
/// Pushed into the App Library's NavigationStack — no own NavigationStack.
struct NutritionRootView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(\.modelContext) private var context

    @State private var selectedTab = 0
    @State private var addFoodMeal: MealSlot? = nil
    @State private var goal: NutritionGoal = NutritionGoal()
    @State private var todayEntries: [FoodLogEntry] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            DiaryTab(
                goal: goal,
                entries: todayEntries,
                onAddFood: { meal in addFoodMeal = meal },
                onDelete: deleteEntry
            )
            .tabItem { Label("Today", systemImage: "fork.knife") }
            .tag(0)

            NutritionHistoryView(goal: goal)
                .tabItem { Label("History", systemImage: "chart.bar.fill") }
                .tag(1)

            NutritionGoalsView(goal: goal) { saved in
                context.insert(saved)
                try? context.save()
                goal = saved
            }
            .tabItem { Label("Goals", systemImage: "target") }
            .tag(2)
        }
        .navigationTitle("Nutrition")
        .sheet(item: $addFoodMeal) { meal in
            AddFoodView(meal: meal) { entry in
                context.insert(entry)
                try? context.save()
                core.log(module: "nutrition", action: "logged-food",
                         summary: "\(entry.foodName) (\(Int(entry.kcal)) kcal)", metric: entry.kcal)
                loadToday()
            }
        }
        .task { loadGoal(); loadToday() }
    }

    private func loadGoal() {
        var d = FetchDescriptor<NutritionGoal>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 1
        goal = (try? context.fetch(d))?.first ?? NutritionGoal()
    }

    private func loadToday() {
        let start = Calendar.current.startOfDay(for: .now)
        let d = FetchDescriptor<FoodLogEntry>(
            predicate: #Predicate { $0.loggedAt >= start },
            sortBy: [SortDescriptor(\.loggedAt)]
        )
        todayEntries = (try? context.fetch(d)) ?? []
    }

    private func deleteEntry(_ entry: FoodLogEntry) {
        context.delete(entry)
        try? context.save()
        loadToday()
    }
}

// MARK: - Today Diary

struct DiaryTab: View {
    let goal: NutritionGoal
    let entries: [FoodLogEntry]
    let onAddFood: (MealSlot) -> Void
    let onDelete: (FoodLogEntry) -> Void

    private var totalKcal: Double    { entries.reduce(0) { $0 + $1.kcal } }
    private var totalProtein: Double { entries.reduce(0) { $0 + $1.proteinG } }
    private var totalCarbs: Double   { entries.reduce(0) { $0 + $1.carbsG } }
    private var totalFat: Double     { entries.reduce(0) { $0 + $1.fatG } }

    private var budget: NutritionBudget {
        NutritionBudget(consumed: totalKcal, goal: goal.dailyKcal, activeBurned: 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SnappetSpacing.xl) {
                CalorieBudgetRing(budget: budget)
                    .padding(.top, SnappetSpacing.lg)

                MacroBarsView(
                    protein: totalProtein, proteinGoal: goal.proteinG,
                    carbs: totalCarbs, carbsGoal: goal.carbsG,
                    fat: totalFat, fatGoal: goal.fatG
                )

                ForEach(MealSlot.allCases, id: \.self) { meal in
                    MealSectionView(
                        meal: meal,
                        entries: entries.filter { $0.mealSlot == meal },
                        onAdd: { onAddFood(meal) },
                        onDelete: onDelete
                    )
                }

                AttributionFooter()
            }
            .padding(.horizontal, SnappetSpacing.lg)
            .padding(.bottom, SnappetSpacing.xxl)
        }
        .accessibilityIdentifier("nutrition.diary")
    }
}

// MARK: - Calorie ring

struct CalorieBudgetRing: View {
    let budget: NutritionBudget

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: budget.ringFraction)
                .stroke(
                    budget.remaining < 0 ? Color.red : SnappetColor.moduleAccent("nutrition"),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: budget.ringFraction)
            VStack(spacing: 2) {
                Text("\(Int(budget.consumed))")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("of \(Int(budget.goal)) kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(budget.remaining >= 0
                     ? "\(Int(budget.remaining)) remaining"
                     : "\(Int(-budget.remaining)) over")
                    .font(.caption2)
                    .foregroundStyle(budget.remaining < 0 ? .red : .secondary)
            }
        }
        .frame(width: 190, height: 190)
        .accessibilityIdentifier("nutrition.budgetRing")
    }
}

// MARK: - Macro bars

struct MacroBarsView: View {
    let protein: Double; let proteinGoal: Double
    let carbs: Double;   let carbsGoal: Double
    let fat: Double;     let fatGoal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Macros").font(.headline)
            MacroBar(label: "Protein", value: protein, goal: proteinGoal, color: .blue)
            MacroBar(label: "Carbs",   value: carbs,   goal: carbsGoal,   color: .orange)
            MacroBar(label: "Fat",     value: fat,     goal: fatGoal,     color: .yellow)
        }
        .padding(SnappetSpacing.lg)
        .snappetCard()
        .accessibilityIdentifier("nutrition.macroBars")
    }
}

private struct MacroBar: View {
    let label: String; let value: Double; let goal: Double; let color: Color
    private var fraction: Double { min(value / max(goal, 1), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(value)) / \(Int(goal)) g").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 8)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * fraction, height: 8)
                        .animation(.easeOut, value: fraction)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Meal section

struct MealSectionView: View {
    let meal: MealSlot
    let entries: [FoodLogEntry]
    let onAdd: () -> Void
    let onDelete: (FoodLogEntry) -> Void

    private var totalKcal: Double { entries.reduce(0) { $0 + $1.kcal } }

    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            HStack {
                Text(meal.rawValue).font(.headline)
                Spacer()
                Text("\(Int(totalKcal)) kcal").font(.caption).foregroundStyle(.secondary)
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(SnappetColor.moduleAccent("nutrition"))
                }
                .accessibilityIdentifier("nutrition.addFood.\(meal.rawValue.lowercased())")
            }
            if entries.isEmpty {
                Text("Nothing logged yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(entries) { entry in
                    FoodEntryRow(entry: entry) { onDelete(entry) }
                    if entry.id != entries.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(SnappetSpacing.lg)
        .snappetCard()
        .accessibilityIdentifier("nutrition.meal.\(meal.rawValue.lowercased())")
    }
}

private struct FoodEntryRow: View {
    let entry: FoodLogEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: SnappetSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.foodName).font(.subheadline)
                Text("\(entry.servings.formatted(.number.precision(.fractionLength(0...1)))) × \(Int(entry.servingGrams)) g")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(entry.kcal)) kcal").font(.caption.bold())
            Button(action: onDelete) {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .accessibilityIdentifier("nutrition.entry.\(entry.id)")
    }
}

// MARK: - Attribution footer

private struct AttributionFooter: View {
    var body: some View {
        VStack(spacing: SnappetSpacing.xs) {
            Text("Data from Open Food Facts — ODbL | USDA FoodData Central")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Text("Nutrition data may be inaccurate. Not medical advice.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, SnappetSpacing.md)
    }
}
