import SwiftUI

/// Reusable editor sheet for a Habit's name + symbol, used for both **create** (pass `habit: nil`)
/// and **edit** (pass an existing `Habit`). The sheet carries its own `NavigationStack` (allowed —
/// only the *pushed* root view must avoid nesting one). On save it hands the trimmed name + chosen
/// symbol back to the caller, which performs the actual SwiftData insert/update.
struct HabitEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// What Save hands back (prompt 137 added the days + skip policy).
    struct Result {
        var name: String
        var symbol: String
        /// nil = every day.
        var weekdays: [Int]?
        var skipsBreakStreak: Bool
    }

    /// The habit being edited, or `nil` when creating a new one.
    let habit: Habit?
    /// Routines that tick this habit off (prompt 137). Non-empty ⇒ their schedules decide the days.
    let linkedRoutines: [Routine]
    let unlink: (() -> Void)?
    /// Called with the (trimmed) name, symbol, days and skip policy when the user taps Save.
    let onSave: (Result) -> Void

    @State private var name: String
    @State private var symbol: String
    @State private var specificDays: Bool
    @State private var weekdays: Set<Int>
    @State private var skipsBreakStreak: Bool
    @State private var confirmingUnlink = false

    /// A small shared palette of SF Symbols to pick from.
    static let symbols = [
        "checkmark.circle", "drop.fill", "book.fill", "figure.run",
        "dumbbell.fill", "leaf.fill", "bed.double.fill", "cup.and.saucer.fill",
        "moon.fill", "sun.max.fill", "pencil", "heart.fill"
    ]

    init(habit: Habit? = nil, linkedRoutines: [Routine] = [], unlink: (() -> Void)? = nil,
         onSave: @escaping (Result) -> Void) {
        self.habit = habit
        self.linkedRoutines = linkedRoutines.filter { $0.schedule != nil }
        self.unlink = unlink
        self.onSave = onSave
        _name = State(initialValue: habit?.name ?? "")
        _symbol = State(initialValue: habit?.symbol ?? "checkmark.circle")
        let days = Set(habit?.weekdays ?? [])
        _specificDays = State(initialValue: !days.isEmpty && days.count < 7)
        _weekdays = State(initialValue: days.isEmpty ? [2, 3, 4, 5, 6] : days)
        _skipsBreakStreak = State(initialValue: habit?.skipsBreakStreak == true)
    }

    private var isEditing: Bool { habit != nil }
    private var isLinked: Bool { !linkedRoutines.isEmpty }

    private var result: Result {
        let days: [Int]? = specificDays && !weekdays.isEmpty && weekdays.count < 7 ? weekdays.sorted() : nil
        return Result(name: trimmedName, symbol: symbol, weekdays: days, skipsBreakStreak: skipsBreakStreak)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Habit") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("habit.nameField")
                }
                Section("Symbol") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { sym in
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
                            .accessibilityIdentifier("habit.symbol.\(sym)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                daysSection
                if isLinked { linkedSection }
            }
            .navigationTitle(isEditing ? "Edit Habit" : "New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        onSave(result)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || (specificDays && weekdays.isEmpty && !isLinked))
                    .accessibilityIdentifier("habit.save")
                }
            }
        }
    }

    // MARK: - Days (prompt 137)

    @ViewBuilder private var daysSection: some View {
        Section {
            if isLinked {
                // The linked routine's schedule decides — shown, not editable, so the two can't disagree.
                ForEach(linkedRoutines) { r in
                    LabeledContent(r.name, value: r.schedule?.summary() ?? "")
                }
            } else {
                Picker("Days", selection: $specificDays) {
                    Text("Every day").tag(false)
                    Text("Specific days").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("habit.daysMode")
                if specificDays { WeekdayPicker(selection: $weekdays) }
            }
        } header: {
            Text("Days")
        } footer: {
            if isLinked {
                Text("Set by the linked routine's schedule. Change it there, or unlink below.")
            } else if specificDays {
                Text("Your streak counts these days only — a day off never breaks it.")
            }
        }
    }

    private var linkedSection: some View {
        Section {
            Picker("Skipped days count as", selection: $skipsBreakStreak) {
                Text("Excused").tag(false)
                Text("Missed").tag(true)
            }
            .accessibilityIdentifier("habit.skipPolicy")
            if let unlink {
                Button("Unlink from routine\(linkedRoutines.count == 1 ? "" : "s")", role: .destructive) {
                    confirmingUnlink = true
                }
                .accessibilityIdentifier("habit.unlink")
                .confirmationDialog("Unlink this habit?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
                    Button("Unlink", role: .destructive) { unlink(); dismiss() }
                } message: {
                    Text("The habit and its history stay; finishing the routine just won't tick it off any more.")
                }
            }
        } header: {
            Text("Linked routine\(linkedRoutines.count == 1 ? "" : "s")")
        } footer: {
            Text("\"Skip today\" on a routine reminder either keeps your streak alive (Excused) or ends it (Missed).")
        }
    }
}
