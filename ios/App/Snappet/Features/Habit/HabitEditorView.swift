import SwiftUI

/// Reusable editor sheet for a Habit's name + symbol, used for both **create** (pass `habit: nil`)
/// and **edit** (pass an existing `Habit`). The sheet carries its own `NavigationStack` (allowed —
/// only the *pushed* root view must avoid nesting one). On save it hands the trimmed name + chosen
/// symbol back to the caller, which performs the actual SwiftData insert/update.
struct HabitEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// The habit being edited, or `nil` when creating a new one.
    let habit: Habit?
    /// Called with the (trimmed) name and chosen symbol when the user taps Save.
    let onSave: (String, String) -> Void

    @State private var name: String
    @State private var symbol: String

    /// A small shared palette of SF Symbols to pick from.
    static let symbols = [
        "checkmark.circle", "drop.fill", "book.fill", "figure.run",
        "dumbbell.fill", "leaf.fill", "bed.double.fill", "cup.and.saucer.fill",
        "moon.fill", "sun.max.fill", "pencil", "heart.fill"
    ]

    init(habit: Habit? = nil, onSave: @escaping (String, String) -> Void) {
        self.habit = habit
        self.onSave = onSave
        _name = State(initialValue: habit?.name ?? "")
        _symbol = State(initialValue: habit?.symbol ?? "checkmark.circle")
    }

    private var isEditing: Bool { habit != nil }

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
            }
            .navigationTitle(isEditing ? "Edit Habit" : "New Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        onSave(trimmedName, symbol)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("habit.save")
                }
            }
        }
    }
}
