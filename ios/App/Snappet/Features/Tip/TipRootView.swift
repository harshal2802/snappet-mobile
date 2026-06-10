import SwiftUI
import SwiftData

/// Route value for the Tip mini-app's pushed History screen. Pushed onto the App
/// Library's shared `SuiteRouter` path; `TipRootView` vends the destination.
struct TipHistoryRoute: Hashable {}

/// Tip Calculator: enter a bill, pick a tip percentage, split between people, and see
/// live currency-formatted results. Logs one usage event per settled calculation
/// (when the bill field commits) so the Home dashboard can aggregate finance activity,
/// and persists a `TipCalculation` so past splits are browsable from History.
///
/// Pushed into the suite's NavigationStack by the App Library — owns no NavigationStack
/// of its own. Deeper screens (History) push onto the shared `SuiteRouter` path.
struct TipRootView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    /// Raw bill amount. `0` (or empty) means "no meaningful calculation yet".
    @State private var bill: Double = 0
    /// Persisted between launches so the user's usual habits are pre-filled.
    @AppStorage("tip.lastTipPercent") private var tipPercent: Double = 18
    @AppStorage("tip.lastSplitCount") private var splitCount: Int = 1
    /// Round the grand total up to the nearest whole currency unit when on.
    @AppStorage("tip.roundUp") private var roundUpEnabled: Bool = false
    /// The four editable preset percentages (default 15/18/20/25).
    @AppStorage("tip.preset.0") private var preset0: Double = 15
    @AppStorage("tip.preset.1") private var preset1: Double = 18
    @AppStorage("tip.preset.2") private var preset2: Double = 20
    @AppStorage("tip.preset.3") private var preset3: Double = 25
    /// Drives focus so we can dismiss the keypad and treat that as a commit.
    @FocusState private var billFocused: Bool
    /// Whether the preset-editor sheet is showing.
    @State private var editingPresets = false

    private var presets: [Double] { [preset0, preset1, preset2, preset3] }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    /// Base (pre-round-up) tip and total from the raw inputs.
    private var rawTipAmount: Double { max(0, bill) * tipPercent / 100 }
    private var rawTotal: Double { max(0, bill) + rawTipAmount }

    /// The displayed total: rounded up to the nearest whole currency unit when the
    /// round-up toggle is on, otherwise the raw total.
    private var total: Double {
        roundUpEnabled ? rawTotal.rounded(.up) : rawTotal
    }

    /// Tip portion, back-computed from the (possibly rounded-up) total so it stays
    /// consistent with the bill the user sees.
    private var tipAmount: Double { max(0, total - max(0, bill)) }

    /// Effective tip percentage after any round-up (what we persist/log).
    private var effectiveTipPct: Double {
        bill > 0 ? tipAmount / bill * 100 : tipPercent
    }

    private var perPerson: Double { total / Double(max(1, splitCount)) }

    /// Whether the current tip% matches a preset (so the segmented control shows it
    /// selected). `nil` means the value came from the custom slider.
    private var selectedPreset: Double? {
        presets.first { abs($0 - tipPercent) < 0.5 }
    }

    var body: some View {
        Form {
            billSection
            tipSection
            splitSection
            resultsSection
        }
        .navigationTitle("Tip Calculator")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    router.push(TipHistoryRoute())
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("tip.history")
            }
        }
        // The pattern this view pioneered, now shared suite-wide (issue #82).
        .keypadDoneToolbar($billFocused)
        .navigationDestination(for: TipHistoryRoute.self) { _ in
            TipHistoryView()
        }
        .sheet(isPresented: $editingPresets) {
            TipPresetEditor(presets: [$preset0, $preset1, $preset2, $preset3])
        }
        // Committing the keypad (Done / dismiss) settles the calculation -> log once.
        .onChange(of: billFocused) { _, focused in
            if !focused { commitCalculation() }
        }
    }

    // MARK: - Sections

    private var billSection: some View {
        Section("Bill") {
            HStack {
                Text(currencySymbol)
                    .foregroundStyle(.secondary)
                TextField("Amount", value: $bill, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .focused($billFocused)
                    .submitLabel(.done)
                    .onSubmit { billFocused = false }
                    .accessibilityIdentifier("tip.bill")
            }
            .font(.title3)
        }
    }

    private var tipSection: some View {
        Section {
            Picker("Tip percentage", selection: presetBinding) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                    Text("\(Int(preset))%")
                        .tag(Optional(preset))
                        .accessibilityIdentifier("tip.preset.\(index)")
                }
                if selectedPreset == nil {
                    Text("Custom").tag(Optional<Double>.none)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading) {
                HStack {
                    Text("Custom")
                    Spacer()
                    Text("\(Int(tipPercent.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $tipPercent, in: 0...40, step: 1) {
                    Text("Tip percentage")
                }
                .accessibilityIdentifier("tip.customPct")
            }
        } header: {
            HStack {
                Text("Tip")
                Spacer()
                Button("Edit presets") { editingPresets = true }
                    .font(.caption)
                    .textCase(nil)
                    .accessibilityIdentifier("tip.editPresets")
            }
        }
    }

    private var splitSection: some View {
        Section("Split") {
            Stepper(value: $splitCount, in: 1...20) {
                HStack {
                    Text("People")
                    Spacer()
                    Text("\(splitCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("tip.people")

            Toggle("Round up total", isOn: $roundUpEnabled)
                .accessibilityIdentifier("tip.roundUp")
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            resultRow("Tip", amount: tipAmount)
            resultRow("Total", amount: total)
                .accessibilityIdentifier("tip.total")
            resultRow("Per person", amount: perPerson, emphasized: true)
                .accessibilityIdentifier("tip.perPerson")
        }
    }

    private func resultRow(_ label: String, amount: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            Text(amount.formatted(.currency(code: currencyCode)))
                .monospacedDigit()
                .contentTransition(.numericText())
                .fontWeight(emphasized ? .bold : .regular)
                .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                // Totals move toward their new value as the bill/tip/split change (issue #30 §5.8).
                .animation(.snappy, value: amount)
        }
    }

    // MARK: - Helpers

    /// Picking a preset writes its value into `tipPercent`; the slider can still set
    /// arbitrary values, which deselects the segmented control.
    private var presetBinding: Binding<Double?> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                if let newValue { tipPercent = newValue }
            }
        )
    }

    private var currencySymbol: String {
        Locale.current.currencySymbol ?? "$"
    }

    /// Settle the calculation: log a usage event (dashboard) and persist a
    /// `TipCalculation` (history). Effective tip% reflects any round-up.
    private func commitCalculation() {
        guard bill > 0 else { return }
        core.log(
            module: "tip",
            action: "calc",
            summary: "Tip on \(bill.formatted(.currency(code: currencyCode)))",
            metric: tipAmount
        )
        modelContext.insert(TipCalculation(
            bill: bill,
            tipPct: effectiveTipPct,
            people: splitCount,
            tipAmount: tipAmount,
            total: total
        ))
        try? modelContext.save()
    }
}

/// A small sheet for editing the four preset tip percentages. Each is a stepper
/// bound directly to the owning view's `@AppStorage` value, so edits persist.
private struct TipPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let presets: [Binding<Double>]

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset percentages") {
                    ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                        Stepper(value: preset, in: 0...100, step: 1) {
                            HStack {
                                Text("Preset \(index + 1)")
                                Spacer()
                                Text("\(Int(preset.wrappedValue.rounded()))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("tip.presetEdit.\(index)")
                    }
                }
            }
            .navigationTitle("Edit Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tip.presetEdit.done")
                }
            }
        }
    }
}
