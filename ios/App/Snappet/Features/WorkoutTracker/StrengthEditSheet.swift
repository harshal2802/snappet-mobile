import SwiftUI

/// The captured details of a strength exercise (Workout-Type Parity, strength polish): an optional
/// display-name override + a default prescription (sets × reps × weight × unit). Stored on the
/// `SessionExercise` (`displayName` + the `target*` columns), so it's the strength analogue of
/// `AddClimbParams`. The default seeds the card's quick-add for a fresh exercise. Pure value → testable.
struct AddStrengthParams: Equatable, Sendable {
    /// Display-name override; "" ⇒ keep the catalog name (no override).
    var name: String
    var sets: Int
    var reps: Int
    var weight: Double?
    var unit: WeightUnit

    init(name: String = "", sets: Int = 3, reps: Int = 8, weight: Double? = nil, unit: WeightUnit = .kg) {
        self.name = name
        self.sets = max(1, sets)
        self.reps = max(1, reps)
        self.weight = weight
        self.unit = unit
    }

    /// Seed from an existing exercise for edit-in-place — empty `target*` (a bulk-added exercise) falls
    /// back to sensible defaults (3 × 8) so the sheet opens populated.
    init(from ex: SessionExercise) {
        name = ex.displayName ?? ""
        sets = ex.targetSets > 0 ? ex.targetSets : 3
        reps = Int(ex.targetReps) ?? 8
        weight = ex.targetWeight
        unit = ex.targetWeightUnit ?? .kg
    }
}

/// "Exercise details" sheet for a strength entity (Workout-Type Parity, strength polish). The hybrid-add
/// payoff + inline edit in one surface: rename the exercise and set its default sets × reps × weight × unit
/// (which seeds the card's quick-add), reachable from the card's ⋯ → "Edit details". A one-tap "Last time"
/// chip fills the default from the cross-session prefill. Reused for "set defaults after a fast bulk add"
/// and "edit/rename later".
struct StrengthEditSheet: View {
    let catalogName: String
    /// The cross-session last set for this exercise (the "Last time" quick-fill chip); nil hides it.
    let lastReps: Int?
    let lastWeight: Double?
    let lastUnit: WeightUnit?
    let onSave: (AddStrengthParams) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var p: AddStrengthParams
    @State private var weightText: String

    init(catalogName: String, initial: AddStrengthParams,
         lastReps: Int? = nil, lastWeight: Double? = nil, lastUnit: WeightUnit? = nil,
         onSave: @escaping (AddStrengthParams) -> Void) {
        self.catalogName = catalogName
        self.lastReps = lastReps
        self.lastWeight = lastWeight
        self.lastUnit = lastUnit
        self.onSave = onSave
        _p = State(initialValue: initial)
        _weightText = State(initialValue: initial.weight.map { SetMeasure.formatWeight($0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(catalogName, text: $p.name)
                        .accessibilityIdentifier("editStrength.name")
                }
                Section("Default set") {
                    Stepper("Sets: \(p.sets)", value: $p.sets, in: 1...20)
                        .accessibilityIdentifier("editStrength.sets")
                    Stepper("Reps: \(p.reps)", value: $p.reps, in: 1...100)
                        .accessibilityIdentifier("editStrength.reps")
                    HStack {
                        Text("Weight")
                        TextField("Body", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("editStrength.weight")
                        Picker("Unit", selection: $p.unit) {
                            Text("kg").tag(WeightUnit.kg)
                            Text("lb").tag(WeightUnit.lb)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 96)
                        .labelsHidden()
                    }
                }
                if let lr = lastReps {
                    Section {
                        Button {
                            p.reps = lr
                            p.weight = lastWeight
                            if let u = lastUnit { p.unit = u }
                            weightText = lastWeight.map { SetMeasure.formatWeight($0) } ?? ""
                        } label: {
                            Label("Last time: \(lastTimeLabel(lr))", systemImage: "clock.arrow.circlepath")
                        }
                        .accessibilityIdentifier("editStrength.lastTime")
                    }
                }
            }
            .navigationTitle("Exercise details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var out = p
                        out.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        out.weight = SetMeasure.parseWeight(weightText)
                        onSave(out)
                        dismiss()
                    }
                    .accessibilityIdentifier("editStrength.save")
                }
            }
        }
    }

    private func lastTimeLabel(_ reps: Int) -> String {
        if let w = lastWeight {
            return "\(reps) × \(SetMeasure.formatWeight(w)) \((lastUnit ?? .kg).display)"
        }
        return "\(reps) reps"
    }
}
