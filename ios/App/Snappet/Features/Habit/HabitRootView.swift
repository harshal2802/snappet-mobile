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
    @Environment(SuiteRouter.self) private var router

    @Query(sort: \Habit.createdAt, order: .forward) private var habits: [Habit]
    @Query private var completions: [HabitCompletion]
    /// Routines, to resolve which habits are linked to a schedule (prompt 137).
    @Query private var routines: [Routine]

    @State private var showingAdd = false
    /// The habit currently being edited via the editor sheet, if any.
    @State private var editingHabit: Habit?
    /// The habit pending delete confirmation, if any.
    @State private var pendingDelete: Habit?
    /// Incremented when a streak milestone is crossed — drives `.celebrates(on:)`.
    @State private var celebrationTrigger = 0
    /// Milestones already celebrated this launch, per habit — unchecking and re-checking
    /// today must not replay the same burst (review fix).
    @State private var celebratedMilestones: [UUID: Set<Int>] = [:]

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
            HabitEditorView { result in addHabit(result) }
        }
        .sheet(item: $editingHabit) { habit in
            HabitEditorView(habit: habit, linkedRoutines: linkedRoutines(for: habit),
                            unlink: { unlink(habit) }) { result in update(habit, result) }
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
                let schedule = schedule(for: habit)
                HabitRow(
                    habit: habit,
                    index: index,
                    streak: streak(for: habit),
                    completionRate: completionRate(for: habit),
                    weekDays: weekStrip(for: habit),
                    isDoneToday: isDoneToday(habit),
                    scheduleLine: scheduleLine(habit, schedule),
                    linked: linkedToday(for: habit),
                    startLinked: { routine in
                        router.pendingRoutineStart = routine.id
                        router.open(module: "workout-log")
                    },
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

    /// Which days this habit is due — every day, its weekdays, or its linked routines' schedules (137).
    private func schedule(for habit: Habit) -> HabitSchedule {
        HabitSchedule.resolve(habit, routines: routines)
    }

    private func linkedRoutines(for habit: Habit) -> [Routine] {
        routines.filter { $0.linkedHabitID == habit.id }.sorted { $0.name < $1.name }
    }

    /// The last 7 calendar days (oldest → today) with each day's done / due state, for the week strip.
    private func weekStrip(for habit: Habit) -> [WeekDay] {
        let done = completionDays(for: habit)
        let schedule = schedule(for: habit)
        let today = calendar.startOfDay(for: .now)
        // offset 6 (oldest) … 0 (today), laid out left→right.
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = DayKey(day, calendar: calendar)
            return WeekDay(offset: offset, date: day, isDone: done.contains(day),
                           isDue: schedule.isScheduled(key, calendar: calendar),
                           isSkipped: (habit.skippedDayKeys ?? []).contains(key.value))
        }
    }

    /// Current streak over the habit's due days, ending today (or the last due day before it). The
    /// math lives in the pure `HabitMilestones.streak` so the toggle-time celebration shares one definition.
    private func streak(for habit: Habit) -> Int {
        HabitMilestones.streak(days: completionDays(for: habit), today: .now,
                               schedule: schedule(for: habit), calendar: calendar)
    }

    /// Share of due days done over the trailing 30 days (or since creation) — pure in `HabitMilestones`.
    private func completionRate(for habit: Habit) -> Double {
        HabitMilestones.completionRate(days: completionDays(for: habit), createdAt: habit.createdAt,
                                       today: .now, schedule: schedule(for: habit), calendar: calendar)
    }

    /// "Mon · Wed · Fri" / "Every day" / the linked routine's summary.
    private func scheduleLine(_ habit: Habit, _ schedule: HabitSchedule) -> String {
        if schedule.isLinked {
            let names = linkedRoutines(for: habit).filter { $0.schedule != nil }.map(\.name)
            return names.count == 1 ? (linkedRoutines(for: habit).first?.schedule?.summary() ?? "")
                : "\(names.count) routines"
        }
        guard let days = schedule.weekdays else { return "Every day" }
        return RoutineSchedule.orderedWeekdays(calendar).filter(days.contains)
            .map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: " · ")
    }

    /// The linked routine planned today (and when), for the row's Start strip.
    private func linkedToday(for habit: Habit) -> LinkedToday? {
        let today = DayKey(.now, calendar: calendar)
        let linked = linkedRoutines(for: habit)
        guard !linked.isEmpty else { return nil }
        if let r = linked.first(where: { $0.schedule.map { $0.isEnabled && $0.occurs(on: today, calendar: calendar) } ?? false }),
           let s = r.schedule {
            return LinkedToday(routine: r, todayAt: s.startTime(on: today, calendar: calendar))
        }
        return LinkedToday(routine: linked[0], todayAt: nil)
    }

    // MARK: - Mutations

    private func addHabit(_ result: HabitEditorView.Result) {
        let trimmed = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let habit = Habit(name: trimmed, symbol: result.symbol)
        habit.weekdays = result.weekdays
        context.insert(habit)
        try? context.save()
        core.log(module: "habit", action: "create", summary: "Added habit: \(trimmed)")
    }

    private func update(_ habit: Habit, _ result: HabitEditorView.Result) {
        let trimmed = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        habit.name = trimmed
        habit.symbol = result.symbol
        habit.weekdays = result.weekdays
        habit.skipsBreakStreak = result.skipsBreakStreak ? true : nil
        try? context.save()
        core.log(module: "habit", action: "edit", summary: "Edited habit: \(trimmed)")
    }

    /// Stop auto-completing from routines; the habit and its history stay (wireframe frame 7).
    private func unlink(_ habit: Habit) {
        HabitRoutineLink.unlinkAll(habitID: habit.id, in: context)
        try? context.save()
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
            let sched = schedule(for: habit)
            let streakBefore = HabitMilestones.streak(days: daysBefore, today: .now, schedule: sched,
                                                      calendar: calendar)
            let streakAfter = HabitMilestones.streak(days: daysBefore.union([normalized]),
                                                     today: .now, schedule: sched, calendar: calendar)

            context.insert(HabitCompletion(habitID: habit.id, day: normalized))
            try? context.save()
            let isToday = calendar.isDateInToday(normalized)
            core.log(
                module: "habit",
                action: isToday ? "done" : "backfill",
                summary: isToday ? "Did: \(habit.name)" : "Backfilled: \(habit.name)"
            )
            if let milestone = HabitMilestones.crossed(previousStreak: streakBefore, newStreak: streakAfter),
               !(celebratedMilestones[habit.id]?.contains(milestone) ?? false) {
                celebratedMilestones[habit.id, default: []].insert(milestone)
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
        HabitRoutineLink.unlinkAll(habitID: habit.id, in: context)
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
    /// Due that day (prompt 137). Off-schedule days draw dashed and don't count.
    var isDue: Bool = true
    var isSkipped: Bool = false

    var id: Int { offset }
}

/// A linked routine for the habit row's Start strip (prompt 137). `todayAt` nil = not planned today.
struct LinkedToday {
    let routine: Routine
    let todayAt: Date?
}

// MARK: - Row

private struct HabitRow: View {
    let habit: Habit
    let index: Int
    let streak: Int
    let completionRate: Double
    let weekDays: [WeekDay]
    let isDoneToday: Bool
    let scheduleLine: String
    let linked: LinkedToday?
    let startLinked: (Routine) -> Void
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
                    Text("\(scheduleLine) · \(ratePercent) last 30 days")
                        .lineLimit(1)
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
            if let linked { linkedStrip(linked) }
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
            .tint(SnappetColor.habits)
        }
        .contextMenu {
            Button { edit() } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { requestDelete() } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// "🔗 Linked to Push Day · today 7:00 AM   ▶ Start" (wireframe frame 6).
    private func linkedStrip(_ linked: LinkedToday) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link").font(.caption)
            Group {
                // Named after its routine (the default) → don't repeat the name; it's right above.
                let who = linked.routine.name == habit.name ? "Linked routine" : "Linked to **\(linked.routine.name)**"
                // LocalizedStringKey(_:) so the **bold** name renders (a String interpolated into Text
                // is inserted verbatim, asterisks and all).
                if let at = linked.todayAt {
                    Text(LocalizedStringKey("\(who) · today \(at.formatted(date: .omitted, time: .shortened))"))
                } else {
                    Text(LocalizedStringKey(who))
                }
            }
            .font(.caption).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if linked.todayAt != nil, !isDoneToday {
                Button { startLinked(linked.routine) } label: {
                    Label("Start", systemImage: "play.fill").font(.caption.weight(.semibold))
                        .imageScale(.small)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .tint(SnappetColor.workout).controlSize(.small)
                .accessibilityIdentifier("habit.startLinked")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
        // .contain first: an id on a bare container is stamped onto every child, hiding the Start button's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("habit.linked")
    }

    /// Linked habits count sessions; others count days.
    private var streakUnit: String { linked != nil ? "session" : "day" }

    @ViewBuilder
    private var streakLabel: some View {
        if streak > 0 {
            Label("\(streak) \(streakUnit)\(streak == 1 ? "" : "s") streak", systemImage: "flame.fill")
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
            .foregroundStyle(SnappetColor.habits)
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

    private var stateText: String {
        if day.isDone { return "done" }
        if day.isSkipped { return "skipped" }
        return day.isDue ? "not done" : "rest day"
    }

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 2) {
                Text(weekdayLetter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ZStack {
                    if day.isDone {
                        Circle().fill(SnappetColor.habits)
                    } else if !day.isDue || day.isSkipped {
                        // Off the schedule (or an excused skip) — drawn as an outline: it doesn't count.
                        Circle().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else {
                        Circle().fill(SnappetColor.habits.opacity(0.12))
                    }
                    if day.isSkipped && !day.isDone {
                        Image(systemName: "arrow.uturn.right").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(dayNumber)
                            .font(.caption2)
                            .foregroundStyle(day.isDone ? Color.white : day.isDue ? Color.secondary : Color.secondary.opacity(0.5))
                    }
                }
                .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(weekdayLetter) \(dayNumber), \(stateText)")
        .accessibilityIdentifier("habit.day.\(day.offset)")
    }
}
