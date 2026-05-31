import SwiftUI
import SwiftData

/// Root screen for the Habit mini-app. Pushed into the App Library's NavigationStack
/// (so it adds no stack of its own). Lists the user's habits with their current streak
/// and a per-day done toggle; habits are added via a sheet and removed via swipe.
struct HabitRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core

    @Query(sort: \Habit.createdAt, order: .forward) private var habits: [Habit]
    @Query private var completions: [HabitCompletion]

    @State private var showingAdd = false

    var body: some View {
        Group {
            if habits.isEmpty {
                ContentUnavailableView {
                    Label("No habits yet", systemImage: "checkmark.seal")
                } description: {
                    Text("Add a habit to start building a daily streak.")
                } actions: {
                    Button("Add Habit") { showingAdd = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .navigationTitle("Habits")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Label("Add Habit", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddHabitView { name, symbol in addHabit(name: name, symbol: symbol) }
        }
    }

    private var list: some View {
        List {
            ForEach(habits) { habit in
                HabitRow(
                    habit: habit,
                    streak: streak(for: habit),
                    isDoneToday: isDoneToday(habit),
                    toggle: { toggleToday(habit) }
                )
            }
            .onDelete(perform: deleteHabits)
        }
    }

    // MARK: - Day helpers

    private var calendar: Calendar { .current }

    /// All completion days for a habit, normalised to start-of-day, as a Set for O(1) lookup.
    private func completionDays(for habit: Habit) -> Set<Date> {
        Set(completions.filter { $0.habitID == habit.id }.map { calendar.startOfDay(for: $0.day) })
    }

    private func isDoneToday(_ habit: Habit) -> Bool {
        completionDays(for: habit).contains(calendar.startOfDay(for: .now))
    }

    /// Current streak = number of consecutive calendar days completed, ending today.
    /// If today isn't done yet we still count a streak ending *yesterday*, so a streak
    /// stays "alive" until midnight passes without completing — only after a full missed
    /// day does it reset to 0.
    private func streak(for habit: Habit) -> Int {
        let days = completionDays(for: habit)
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: .now)
        // Start counting from today if done, otherwise from yesterday.
        var cursor = days.contains(today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today) ?? today

        // If neither today nor yesterday is completed, the streak is broken.
        guard days.contains(cursor) else { return 0 }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    // MARK: - Mutations

    private func addHabit(name: String, symbol: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.insert(Habit(name: trimmed, symbol: symbol))
        try? context.save()
        core.log(module: "habit", action: "create", summary: "Added habit: \(trimmed)")
    }

    private func toggleToday(_ habit: Habit) {
        let today = calendar.startOfDay(for: .now)
        if let existing = completions.first(where: { $0.habitID == habit.id && calendar.isDate($0.day, inSameDayAs: today) }) {
            // Un-mark today.
            context.delete(existing)
            try? context.save()
        } else {
            context.insert(HabitCompletion(habitID: habit.id, day: today))
            try? context.save()
            core.log(module: "habit", action: "done", summary: "Did: \(habit.name)")
        }
    }

    private func deleteHabits(at offsets: IndexSet) {
        for index in offsets {
            let habit = habits[index]
            // Remove the habit and all its completion records.
            for completion in completions where completion.habitID == habit.id {
                context.delete(completion)
            }
            context.delete(habit)
        }
        try? context.save()
    }
}

// MARK: - Row

private struct HabitRow: View {
    let habit: Habit
    let streak: Int
    let isDoneToday: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: habit.symbol)
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name).font(.headline)
                streakLabel
            }

            Spacer()

            Button(action: toggle) {
                Image(systemName: isDoneToday ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(isDoneToday ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDoneToday ? "Mark not done today" : "Mark done today")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var streakLabel: some View {
        if streak > 0 {
            Label("\(streak) day\(streak == 1 ? "" : "s") streak", systemImage: "flame.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        } else {
            Text("No streak yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add sheet

private struct AddHabitView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "checkmark.circle"

    let onAdd: (String, String) -> Void

    /// A small palette of SF Symbols to pick from.
    private let symbols = [
        "checkmark.circle", "drop.fill", "book.fill", "figure.run",
        "dumbbell.fill", "leaf.fill", "bed.double.fill", "cup.and.saucer.fill",
        "moon.fill", "sun.max.fill", "pencil", "heart.fill"
    ]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Habit") {
                    TextField("Name", text: $name)
                }
                Section("Symbol") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(symbols, id: \.self) { sym in
                            Button {
                                symbol = sym
                            } label: {
                                Image(systemName: sym)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(symbol == sym ? Color.green.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(symbol == sym ? .green : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(trimmedName, symbol)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }
}
