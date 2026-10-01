import SwiftUI

/// The editable state of a timed protocol (prompt 140) — name, category and every structure field,
/// including the rest between sets and the get-ready countdown that used to be fixed. Pure value so the
/// preset/edit round-trip is unit-tested; `spec` is what gets stored.
struct ProtocolDraft: Equatable {
    var name: String
    var category: TimedExerciseCategory
    var mode: TimedExerciseSpec.Mode
    var workSec: Int
    var restSec: Int
    var reps: Int
    var sets: Int
    var restBetweenSetsSec: Int
    var leadInSec: Int
    /// Each rep "until I tap done" instead of a fixed hang (prompt 141).
    var selfPaced: Bool
    /// Load (prompt 142): nil = bodyweight; otherwise added / assisted with an amount in `loadUnitRaw`.
    var loadKind: HangLoad.Kind?
    var loadAmount: Double
    var loadUnitRaw: String
    /// nil = both hands.
    var handMode: HandMode?

    init(name: String = "", category: TimedExerciseCategory = .hangboard, spec: TimedExerciseSpec) {
        self.name = name
        self.category = category
        mode = spec.mode
        workSec = spec.workSec
        restSec = spec.restSec
        reps = spec.reps
        sets = spec.sets
        restBetweenSetsSec = spec.restBetweenSetsSec
        leadInSec = spec.leadInSec
        selfPaced = spec.isSelfPaced
        loadKind = spec.load?.kind
        loadAmount = spec.load?.amount ?? 0
        loadUnitRaw = spec.load?.unitRaw
            ?? (UserDefaults.standard.string(forKey: "workoutlog.preferredUnit") == "lb" ? "lb" : "kg")
        handMode = spec.handMode
    }

    private var load: HangLoad? {
        guard let loadKind, loadAmount > 0 else { return nil }
        return HangLoad(kind: loadKind, amount: loadAmount, unitRaw: loadUnitRaw)
    }

    /// The structure being authored. Open count-up carries no parameters; a single hold has no sets.
    var spec: TimedExerciseSpec {
        switch mode {
        case .openCountUp:
            return TimedExerciseSpec(mode: .openCountUp)
        case .maxHang, .countDown:
            return TimedExerciseSpec(mode: mode, workSec: max(1, workSec), reps: 1, sets: 1, leadInSec: leadInSec)
        case .emom:
            return TimedExerciseSpec(mode: mode, workSec: workSec, restSec: restSec, reps: reps, sets: sets,
                                     restBetweenSetsSec: sets > 1 ? restBetweenSetsSec : 0, leadInSec: leadInSec)
        case .repeaters, .tabata:
            // A timed rep needs a length; a tap-done rep ignores it.
            return TimedExerciseSpec(mode: mode, workSec: selfPaced ? workSec : max(1, workSec), restSec: restSec,
                                     reps: reps, sets: sets, restBetweenSetsSec: sets > 1 ? restBetweenSetsSec : 0,
                                     leadInSec: leadInSec, selfPacedWork: selfPaced ? true : nil,
                                     load: load, handMode: handMode)
        }
    }

    /// Pre-fill from a preset — every field, including the ones the old form dropped (rest between sets,
    /// lead-in). The name is left alone unless it's still empty.
    mutating func apply(_ preset: TimedExerciseSpec, name presetName: String? = nil) {
        let keptName = name
        let keptCategory = category
        let keptUnit = loadUnitRaw
        self = ProtocolDraft(name: keptName, category: keptCategory, spec: preset)
        if preset.load == nil { loadUnitRaw = keptUnit }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let presetName { name = presetName }
    }

    var resolvedName: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? mode.label : t
    }
}

/// The protocol editor's form sections (wireframe frame 1), shared by "create" in the pick sheet, editing
/// a saved preset, and "Edit protocol" on a routine block — one editor, so they can't drift. Keeps the
/// `timed.create.*` accessibility ids the existing UI tests drive.
struct ProtocolEditorSections: View {
    @Binding var draft: ProtocolDraft
    /// Mid-run Adjust sheet (prompt 143): only what can change during a run — reps, rests, load, hands.
    var adjustOnly = false

    var body: some View {
        if adjustOnly { adjustBody } else { fullBody }
    }

    @ViewBuilder private var adjustBody: some View {
        Section {
            countRow("Reps per set", id: "adjust.reps", value: $draft.reps, range: 1...100)
            if draft.reps > 1 || draft.handMode?.repMultiplier == 2 {
                durationRow("Rest between reps", id: "adjust.rest", value: $draft.restSec, range: 0...3600)
            }
            if draft.sets > 1 {
                durationRow("Rest between sets", id: "adjust.setRest", value: $draft.restBetweenSetsSec, range: 0...3600)
            }
        } header: {
            Text("This run")
        } footer: {
            Text("Applies from the next phase. The timer keeps running while you adjust.")
        }
        if draft.mode == .repeaters || draft.mode == .tabata {
            loadSection
            handsSection
        }
    }

    @ViewBuilder private var fullBody: some View {
        Section("Name") {
            TextField(draft.mode.label, text: $draft.name)
                .submitLabel(.done)
                .accessibilityIdentifier("timed.create.name")
        }
        Section("Start from") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetChip("Max hangs", key: "maxhangs") { draft.apply(.maxHangs, name: "Max hangs") }
                    presetChip("Repeaters 10:6", key: "endurance") {
                        draft.apply(.enduranceRepeaters, name: "Repeaters 10:6")
                    }
                    presetChip("Contact", key: "contact") { draft.apply(.contact, name: "Contact") }
                    presetChip("Abrahangs", key: "abrahangs") { draft.apply(.abrahangs, name: "Abrahangs") }
                    presetChip("7:3 × 6", key: "repeaters") { draft.apply(.repeaters7x3x6) }
                    presetChip("10s hang", key: "maxhang") { draft.apply(.maxHang10) }
                    presetChip("Tabata", key: "tabata") { draft.apply(.tabata) }
                    presetChip("EMOM", key: "emom") { draft.apply(.emom) }
                    presetChip("Plank 60s", key: "plank") { draft.apply(.hold(60)) }
                }
                .padding(.vertical, 2)
            }
        }
        Section("Category") {
            Picker("Category", selection: $draft.category) {
                ForEach(TimedExerciseCategory.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("timed.create.category")
        }
        structure
        // Load + hands only where the protocol runner logs them (a single hold's stopwatch doesn't —
        // offering them there would be a setting that silently goes nowhere).
        if draft.mode == .repeaters || draft.mode == .tabata {
            loadSection
            handsSection
        }
        Section {
            HStack {
                Text("Total").font(.subheadline.weight(.medium))
                Spacer()
                Text(draft.spec.totalSeconds.map {
                    SetMeasure.formatDuration(Double($0)) + (draft.spec.isSelfPaced ? " + your reps" : "")
                } ?? "Open count up")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SnappetColor.workout)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("timed.create.total")
            }
        }
    }

    @ViewBuilder private var structure: some View {
        Section("Each rep") {
            Picker("Structure", selection: $draft.mode) {
                ForEach(TimedExerciseSpec.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("timed.create.mode")

            switch draft.mode {
            case .openCountUp:
                Text("Times an open-ended hold — no target.").font(.footnote).foregroundStyle(.secondary)
            case .maxHang, .countDown:
                durationRow("Hold for", id: "timed.create.work", value: $draft.workSec, range: 1...3600)
            case .repeaters, .tabata:
                Picker("Each rep", selection: $draft.selfPaced) {
                    Text("Timed hang").tag(false)
                    Text("Until I tap done").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("timed.create.repStyle")
                if !draft.selfPaced {
                    durationRow("Hang for", id: "timed.create.work", value: $draft.workSec, range: 1...3600)
                }
                countRow("Reps per set", id: "timed.create.reps", value: $draft.reps, range: 1...100)
                if draft.reps > 1 {
                    durationRow("Rest between reps", id: "timed.create.rest", value: $draft.restSec, range: 0...3600)
                }
            case .emom:
                countRow("Minutes", id: "timed.create.reps", value: $draft.reps, range: 1...60)
            }
        }
        if draft.mode.isStructured {
            Section("Sets") {
                countRow("Sets", id: "timed.create.sets", value: $draft.sets, range: 1...20)
                if draft.sets > 1 {
                    durationRow("Rest between sets", id: "timed.create.setRest",
                                value: $draft.restBetweenSetsSec, range: 0...3600)
                }
            }
        }
        if draft.mode != .openCountUp {
            Section {
                durationRow("Get-ready countdown", id: "timed.create.leadIn", value: $draft.leadInSec, range: 0...60)
            }
        }
    }

    // MARK: - Load + hands (prompt 142)

    @Environment(AppModel.self) private var app
    @AppStorage(WeightEntry.stepKey(for: .kg)) private var stepKg = 0.0
    @AppStorage(WeightEntry.stepKey(for: .lb)) private var stepLb = 0.0

    private var loadUnit: WeightUnit { draft.loadUnitRaw == "lb" ? .lb : .kg }
    private var loadStep: Double { WeightEntry.step(stored: loadUnit == .lb ? stepLb : stepKg, unit: loadUnit) }

    private var loadSection: some View {
        Section {
            Picker("Load", selection: $draft.loadKind) {
                Text("Bodyweight").tag(HangLoad.Kind?.none)
                Text("+ Added").tag(HangLoad.Kind?.some(.added))
                Text("− Pulley").tag(HangLoad.Kind?.some(.assisted))
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("protocol.loadKind")
            if let kind = draft.loadKind {
                HStack(spacing: 12) {
                    Text(kind == .added ? "Added" : "Taken off").font(.subheadline)
                    Spacer(minLength: 0)
                    Button { draft.loadAmount = WeightEntry.nudge(draft.loadAmount, by: -loadStep) } label: {
                        Image(systemName: "minus.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless).accessibilityIdentifier("protocol.load.minus")
                    .accessibilityLabel("Decrease load")
                    TypeableWeightValue(weight: $draft.loadAmount, unit: loadUnit,
                                        font: .subheadline.weight(.semibold).monospacedDigit(),
                                        id: "protocol.load", zeroLabel: "0 \(loadUnit.display)")
                        .frame(minWidth: 70)
                    Button { draft.loadAmount = WeightEntry.nudge(draft.loadAmount, by: loadStep) } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .buttonStyle(.borderless).accessibilityIdentifier("protocol.load.plus")
                    .accessibilityLabel("Increase load")
                }
                if let total = totalText { LabeledContent(draft.handMode == nil ? "Total on your fingers" : "On one hand", value: total) }
            }
        } header: {
            Text("Load · optional")
        } footer: {
            if draft.loadKind != nil, app.userProfile.profile.weightKg == nil {
                Text("Add your bodyweight in Settings → Heart-rate profile to see the total.")
            }
        }
    }

    /// "80 kg (70 + 10)" in the load's unit, when bodyweight is known.
    private var totalText: String? {
        guard let bw = app.userProfile.profile.weightKg, bw > 0, let kind = draft.loadKind else { return nil }
        let load = HangLoad(kind: kind, amount: draft.loadAmount, unitRaw: draft.loadUnitRaw)
        let toUnit = { (kg: Double) in SetMeasure.formatWeight((WorkoutMath.kgToUnit(kg, self.loadUnit) * 10).rounded() / 10) }
        let sign = kind == .added ? "+" : "−"
        return "\(toUnit(load.totalKg(bodyweightKg: bw))) \(loadUnit.display) (\(toUnit(bw)) \(sign) \(SetMeasure.formatWeight(draft.loadAmount)))"
    }

    private var handsSection: some View {
        Section {
            Picker("Hands", selection: Binding(
                get: { draft.handMode != nil },
                set: { draft.handMode = $0 ? (draft.handMode ?? .alternate) : nil })) {
                Text("Both hands").tag(false)
                Text("One hand").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("protocol.hands")
            if draft.handMode != nil {
                Picker("Which hand", selection: Binding(get: { draft.handMode ?? .alternate },
                                                        set: { draft.handMode = $0 })) {
                    ForEach(HandMode.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("protocol.handMode")
            }
        } header: {
            Text("Hands")
        } footer: {
            if let mode = draft.handMode, mode.repMultiplier == 2 {
                Text("Reps are per hand: \(draft.reps) rep\(draft.reps == 1 ? "" : "s") each side = \(draft.reps * 2) hangs per set.")
            }
        }
    }

    // MARK: - Rows

    /// A duration stepper that moves 1 s / 5 s / 15 s / 1 min depending on the size of the value.
    private func durationRow(_ label: String, id: String, value: Binding<Int>,
                             range: ClosedRange<Int>) -> some View {
        stepper(label, id: id, text: SetMeasure.formatDuration(Double(value.wrappedValue)),
                dec: { value.wrappedValue = DurationStep.next(value.wrappedValue, up: false, range: range) },
                inc: { value.wrappedValue = DurationStep.next(value.wrappedValue, up: true, range: range) })
    }

    private func countRow(_ label: String, id: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        stepper(label, id: id, text: "\(value.wrappedValue)",
                dec: { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) },
                inc: { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) })
    }

    private func stepper(_ label: String, id: String, text: String,
                         dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline)
            Spacer(minLength: 0)
            Button(action: dec) { Image(systemName: "minus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(id).minus")
                .accessibilityLabel("Decrease \(label.lowercased())")
            Text(text).font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 56)
                .accessibilityIdentifier(id)
            Button(action: inc) { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(id).plus")
                .accessibilityLabel("Increase \(label.lowercased())")
        }
    }

    private func presetChip(_ text: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(SnappetColor.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timed.create.preset.\(key)")
    }
}

/// The live plain-English summary, pinned above the editor so every change reads back while you scroll
/// (prompt 140): "3 sets × 3 hangs of 7 s · 2 min between hangs · 4 min between sets · about 21 min".
struct ProtocolSummaryBar: View {
    let spec: TimedExerciseSpec

    var body: some View {
        Text(spec.sentence)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SnappetColor.workout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
            .accessibilityIdentifier("protocol.summary")
    }
}

/// The protocol editor as its own sheet (prompt 140): edit a saved preset, or a routine block's protocol
/// ("Edit protocol", wireframe frame 10). Save hands the draft back; "Save as my preset" (block mode)
/// copies it into your presets without linking the block to it.
struct ProtocolEditorSheet: View {
    let title: String
    let initial: ProtocolDraft
    /// Offer "Save as my preset…" (routine-block mode).
    var offerSaveAsPreset = false
    let onSave: (ProtocolDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var draft: ProtocolDraft
    @State private var savedAsPreset = false

    init(title: String, initial: ProtocolDraft, offerSaveAsPreset: Bool = false,
         onSave: @escaping (ProtocolDraft) -> Void) {
        self.title = title
        self.initial = initial
        self.offerSaveAsPreset = offerSaveAsPreset
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                ProtocolEditorSections(draft: $draft)
                if offerSaveAsPreset {
                    Section {
                        Button(savedAsPreset ? "Saved to my presets ✓" : "Save as my preset…") {
                            context.insert(TimedExerciseCatalog(name: draft.resolvedName, category: draft.category,
                                                                spec: draft.spec))
                            try? context.save()
                            savedAsPreset = true
                        }
                        .disabled(savedAsPreset)
                        .accessibilityIdentifier("protocol.saveAsPreset")
                    } footer: {
                        Text("Your presets appear next to the built-in ones when you add a timed exercise.")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ProtocolSummaryBar(spec: draft.spec) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(draft); dismiss() }
                        .accessibilityIdentifier("protocol.save")
                }
            }
        }
    }
}
