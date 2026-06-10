import SwiftUI
import SwiftData

/// Root screen for the Habit mini-app. Pushed into the App Library's NavigationStack
/// (so it adds no stack of its own). Lists the user's habits with their current streak,
/// a 30-day completion rate, a today toggle, and a tappable 7-day strip to backfill or
/// correct past days. Habits are created/edited via a reusable `HabitEditorView` sheet
/// and deleted via swipe or an explicit confirmation.
struct HabitRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core

    @Query(sort: \Habit.createdAt, order: .forward) private var habits: [Habit]
    @Query private var completions: [HabitCompletion]

    @State private var showingAdd = false
    /// The habit currently being edited via the editor sheet, if any.
    @State private var editingHabit: Habit?
    /// The habit pending delete confirmation, if any.
    @State private var pendingDelete: Habit?
    /// Incremented when a streak milestone is crossed — drives `.celebrates(on:)`.
    @State private var celebrationTrigger = 0

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
                        .accessibilityIdentifier("habit.add")
                }
            } else {
                list
            }
        }
        .navigationTitle("Habits")
        .celebrates(on: celebrationTrigger)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAdd = true } label: {
                    Label("Add Habit", systemImage: "plus")
                }
                .accessibilityIdentifier("habit.add")
            }
        }
        .sheet(isPresented: $showingAdd) {
            HabitEditorView { name, symbol in addHabit(name: name, symbol: symbol) }
        }
        .sheet(item: $editingHabit) { habit in
            HabitEditorView(habit: habit) { name, symbol in update(habit, name: name, symbol: symbol) }
        }
        .confirmationDialog(
            "Delete this habit?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let habit = pendingDelete { delete(habit) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the habit and all its completion history.")
        }
    }

    private var list: some View {
        List {
            ForEach(Array(habits.enumerated()), id: \.element.id) { index, habit in
                HabitRow(
                    habit: habit,
                    index: index,
                    streak: streak(for: habit),
                    completionRate: completionRate(for: habit),
                    weekDays: weekStrip(for: habit),
                    isDoneToday: isDoneToday(habit),
                    toggle: { toggleToday(habit) },
                    toggleDay: { day in toggle(habit, day: day) },
                    edit: { editingHabit = habit },
                    requestDelete: { pendingDelete = habit }
                )
            }
            .onDelete(perform: deleteHabits)
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
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

    /// The last 7 calendar days (oldest → today) with each day's done state, for the week strip.
    private func weekStrip(for habit: Habit) -> [WeekDay] {
        let done = completionDays(for: habit)
        let today = calendar.startOfDay(for: .now)
        // offset 6 (oldest) … 0 (today), laid out left→right.
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return WeekDay(offset: offset, date: day, isDone: done.contains(day))
        }
    }

    /// Current streak = number of consecutive calendar days completed, ending today (or
    /// yesterday — alive until a full missed day). The math lives in the pure
    /// `HabitMilestones.streak` so the toggle-time celebration shares one definition.
    private func streak(for habit: Habit) -> Int {
        HabitMilestones.streak(days: completionDays(for: habit), today: .now, calendar: calendar)
    }

    /// 30-day completion rate: completions in the trailing 30 days ÷ days the habit has existed
    /// (capped at 30). Returns 0 when the habit is brand new with no elapsed days.
    private func completionRate(for habit: Habit) -> Double {
        let today = calendar.startOfDay(for: .now)
        let createdDay = calendar.startOfDay(for: habit.createdAt)
        // Inclusive days since creation, capped at the 30-day window.
        let elapsed = (calendar.dateComponents([.day], from: createdDay, to: today).day ?? 0) + 1
        let window = max(1, min(elapsed, 30))

        guard let windowStart = calendar.date(byAdding: .day, value: -(window - 1), to: today) else { return 0 }
        let done = completionDays(for: habit).filter { $0 >= windowStart && $0 <= today }.count
        return Double(done) / Double(window)
    }

    // MARK: - Mutations

    private func addHabit(name: String, symbol: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        context.insert(Habit(name: trimmed, symbol: symbol))
        try? context.save()
        core.log(module: "habit", action: "create", summary: "Added habit: \(trimmed)")
    }

    private func update(_ habit: Habit, name: String, symbol: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        habit.name = trimmed
        habit.symbol = symbol
        try? context.save()
        core.log(module: "habit", action: "edit", summary: "Edited habit: \(trimmed)")
    }

    private func toggleToday(_ habit: Habit) {
        toggle(habit, day: calendar.startOfDay(for: .now))
    }

    /// Insert or remove a completion for `day` (already start-of-day). Logs `done` for today
    /// and `backfill` for any other (past) day. Completing fires a success haptic, and a
    /// crossed streak milestone (7/30/100) fires the celebration burst (issue #80).
    private func toggle(_ habit: Habit, day: Date) {
        let normalized = calendar.startOfDay(for: day)
        if let existing = completions.first(where: { $0.habitID == habit.id && calendar.isDate($0.day, inSameDayAs: normalized) }) {
            context.delete(existing)
            try? context.save()
        } else {
            // Streak before/after computed on plain day-sets — the @Query refresh timing
            // doesn't matter to the milestone decision.
            let daysBefore = completionDays(for: habit)
            let streakBefore = HabitMilestones.streak(days: daysBefore, today: .now, calendar: calendar)
            let streakAfter = HabitMilestones.streak(days: daysBefore.union([normalized]),
                                                     today: .now, calendar: calendar)

            context.insert(HabitCompletion(habitID: habit.id, day: normalized))
            try? context.save()
            let isToday = calendar.isDateInToday(normalized)
            core.log(
                module: "habit",
                action: isToday ? "done" : "backfill",
                summary: isToday ? "Did: \(habit.name)" : "Backfilled: \(habit.name)"
            )
            if HabitMilestones.crossed(previousStreak: streakBefore, newStreak: streakAfter) != nil {
                celebrationTrigger += 1   // burst + success haptic via .celebrates(on:)
            } else {
                Haptics.success()
            }
        }
    }

    private func delete(_ habit: Habit) {
        for completion in completions where completion.habitID == habit.id {
            context.delete(completion)
        }
        context.delete(habit)
        try? context.save()
    }

    private func deleteHabits(at offsets: IndexSet) {
        for index in offsets {
            delete(habits[index])
        }
    }
}

// MARK: - Week strip model

/// One day in a habit's 7-day strip. `offset` is days before today (0 == today).
private struct WeekDay: Identifiable {
    let offset: Int
    let date: Date
    let isDone: Bool

    var id: Int { offset }
}

// MARK: - Row

private struct HabitRow: View {
    let habit: Habit
    let index: Int
    let streak: Int
    let completionRate: Double
    let weekDays: [WeekDay]
    let isDoneToday: Bool
    let toggle: () -> Void
    let toggleDay: (Date) -> Void
    let edit: () -> Void
    let requestDelete: () -> Void

    private var ratePercent: String {
        let pct = Int((completionRate * 100).rounded())
        return "\(pct)%"
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            HStack(spacing: SnappetSpacing.md) {
                Image(systemName: habit.symbol)
                    .font(.title2)
                    .foregroundStyle(SnappetColor.habits)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(habit.name).font(.headline)
                    streakLabel
                    Text("\(ratePercent) last 30 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("habit.rate.\(index)")
                }

                Spacer()

                Button(action: toggle) {
                    Image(systemName: isDoneToday ? "checkmark.circle.fill" : "circle")
                        .font(.title)
                        .foregroundStyle(isDoneToday ? SnappetColor.habits : Color.secondary)
                        // Checkmark springs/bounces on toggle (issue #30 §5.5).
                        .symbolEffect(.bounce, value: reduceMotion ? false : isDoneToday)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: isDoneToday)
                .accessibilityLabel(isDoneToday ? "Mark not done today" : "Mark done today")
                .accessibilityIdentifier("habit.toggle")
            }

            weekStripView
        }
        .padding(.vertical, SnappetSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("habit.row.\(index)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: requestDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button { edit() } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { requestDelete() } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var streakLabel: some View {
        if streak > 0 {
            Label("\(streak) day\(streak == 1 ? "" : "s") streak", systemImage: "flame.fill")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.workout)
                .contentTransition(.numericText())
                .animation(.snappy, value: streak)
        } else {
            Text("No streak yet")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.textSecondary)
        }
    }

    /// Tappable 7-day strip: each cell backfills/corrects that day's completion.
    private var weekStripView: some View {
        HStack(spacing: 6) {
            // Explicit edit button so the editor is reachable without relying on swipe in tests.
            Button(action: edit) {
                Image(systemName: "pencil")
                    .font(.footnote)
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .accessibilityLabel("Edit habit")
            .accessibilityIdentifier("habit.edit")

            ForEach(weekDays) { day in
                DayCell(day: day) { toggleDay(day.date) }
            }
        }
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let day: WeekDay
    let toggle: () -> Void

    private var weekdayLetter: String {
        let f = DateFormatter()
        f.dateFormat = "EEEEE" // narrow single-letter weekday
        return f.string(from: day.date)
    }

    private var dayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: day.date)
    }

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 2) {
                Text(weekdayLetter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ZStack {
                    Circle()
                        .fill(day.isDone ? SnappetColor.habits : SnappetColor.habits.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Text(dayNumber)
                        .font(.caption2)
                        .foregroundStyle(day.isDone ? .white : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(weekdayLetter) \(dayNumber), \(day.isDone ? "done" : "not done")")
        .accessibilityIdentifier("habit.day.\(day.offset)")
    }
}
