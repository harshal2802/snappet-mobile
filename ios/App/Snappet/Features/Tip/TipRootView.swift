import SwiftUI

/// Tip Calculator: enter a bill, pick a tip percentage, split between people, and see
/// live currency-formatted results. Logs one usage event per settled calculation
/// (when the bill field commits) so the Home dashboard can aggregate finance activity.
///
/// Pushed into the suite's NavigationStack by the App Library — owns no NavigationStack
/// of its own.
struct TipRootView: View {
    @Environment(SnappetCore.self) private var core

    /// Raw bill amount. `0` (or empty) means "no meaningful calculation yet".
    @State private var bill: Double = 0
    /// Persisted between launches so the user's usual habits are pre-filled.
    @AppStorage("tip.lastTipPercent") private var tipPercent: Double = 18
    @AppStorage("tip.lastSplitCount") private var splitCount: Int = 1
    /// Drives focus so we can dismiss the keypad and treat that as a commit.
    @FocusState private var billFocused: Bool

    private static let presets: [Double] = [15, 18, 20, 25]

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    private var tipAmount: Double { max(0, bill) * tipPercent / 100 }
    private var total: Double { max(0, bill) + tipAmount }
    private var perPerson: Double { total / Double(max(1, splitCount)) }

    /// Whether the current tip% matches a preset (so the segmented control shows it
    /// selected). `nil` means the value came from the custom slider.
    private var selectedPreset: Double? {
        Self.presets.first { abs($0 - tipPercent) < 0.5 }
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
            if billFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { billFocused = false }
                }
            }
        }
        // Committing the keypad (Done / dismiss) settles the calculation -> log once.
        .onChange(of: billFocused) { _, focused in
            if !focused { logCalculation() }
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
            }
            .font(.title3)
        }
    }

    private var tipSection: some View {
        Section("Tip") {
            Picker("Tip percentage", selection: presetBinding) {
                ForEach(Self.presets, id: \.self) { preset in
                    Text("\(Int(preset))%").tag(Optional(preset))
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
        }
    }

    private var resultsSection: some View {
        Section("Results") {
            resultRow("Tip", amount: tipAmount)
            resultRow("Total", amount: total)
            resultRow("Per person", amount: perPerson, emphasized: true)
        }
    }

    private func resultRow(_ label: String, amount: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .fontWeight(emphasized ? .semibold : .regular)
            Spacer()
            Text(amount.formatted(.currency(code: currencyCode)))
                .monospacedDigit()
                .fontWeight(emphasized ? .bold : .regular)
                .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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

    private func logCalculation() {
        guard bill > 0 else { return }
        core.log(
            module: "tip",
            action: "calc",
            summary: "Tip on \(bill.formatted(.currency(code: currencyCode)))",
            metric: tipAmount
        )
    }
}
