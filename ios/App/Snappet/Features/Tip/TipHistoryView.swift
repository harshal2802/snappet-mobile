import SwiftUI
import SwiftData

/// Past tip calculations, newest first. Pushed onto the App Library's shared
/// `NavigationStack` (no stack of its own), so `TipRootView` links here via the
/// shared `SuiteRouter`. Supports swipe-to-delete per row and a "Clear all"
/// toolbar action.
struct TipHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TipCalculation.date, order: .reverse) private var calculations: [TipCalculation]

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        Group {
            if calculations.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Calculations you make appear here."))
            } else {
                historyList
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !calculations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear all", role: .destructive) { clearAll() }
                        .accessibilityIdentifier("tip.history.clear")
                }
            }
        }
        .confirmationDialog(
            "Delete this calculation?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let offsets = pendingDeleteOffsets { delete(at: offsets) }
                pendingDeleteOffsets = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteOffsets = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var historyList: some View {
        List {
            ForEach(calculations) { calc in
                TipHistoryRow(calculation: calc, currencyCode: currencyCode)
                    .accessibilityIdentifier("tip.historyRow")
            }
            .onDelete { pendingDeleteOffsets = $0 }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(calculations[index])
        }
        try? modelContext.save()
    }

    private func clearAll() {
        for calc in calculations {
            modelContext.delete(calc)
        }
        try? modelContext.save()
    }
}

/// One history row: bill + tip% + people on top, total + relative date below.
private struct TipHistoryRow: View {
    let calculation: TipCalculation
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(calculation.bill.formatted(.currency(code: currencyCode)))
                    .font(.headline)
                Spacer()
                Text("\(Int(calculation.tipPct.rounded()))% · \(calculation.people)p")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Text("Total \(calculation.total.formatted(.currency(code: currencyCode)))")
                    .font(.subheadline)
                    .monospacedDigit()
                Spacer()
                Text(calculation.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
