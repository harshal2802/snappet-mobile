import SwiftUI
import SwiftData

/// Kilter preferences: the default board + angle that seed browsing, how grades render, and a
/// destructive "clear logged history". Pushed onto the App Library's shared NavigationStack from the
/// catalog's More menu.
struct KilterSettingsView: View {
    let catalog: KilterCatalog
    @Environment(\.modelContext) private var modelContext

    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    @AppStorage("kilter.apiLevel") private var apiLevelRaw = KilterProtocol.APILevel.v3.rawValue

    @Query private var entries: [KilterLogEntry]
    @Query private var sessions: [KilterSession]
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Picker("Board", selection: $layoutId) {
                    ForEach(catalog.layouts()) { Text($0.name).tag($0.id) }
                }
                Picker("Angle", selection: $angle) {
                    ForEach(catalog.angles(), id: \.self) { Text("\($0)°").tag($0) }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Used when you open the Kilter Board.")
            }

            Section("Grades") {
                Picker("Show grades as", selection: $gradeFormatRaw) {
                    ForEach(KilterGradeFormat.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("kilter.settings.gradeFormat")
            }

            Section {
                Picker("Board lights", selection: $apiLevelRaw) {
                    ForEach(KilterProtocol.APILevel.allCases, id: \.rawValue) { level in
                        Text(level.label).tag(level.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("kilter.settings.apiLevel")
            } header: {
                Text("Board protocol")
            } footer: {
                Text("Almost all boards use Standard. If you connect but the wrong holds light up, "
                     + "switch to Legacy — it's for older controllers.")
            }

            Section {
                Button("Clear logged history", role: .destructive) { confirmingClear = true }
                    .disabled(entries.isEmpty)
                    .accessibilityIdentifier("kilter.settings.clearHistory")
            } footer: {
                Text("Removes all \(entries.count) logged ascents and \(sessions.count) sessions. "
                     + "Saved climbs are kept.")
            }
        }
        .navigationTitle("Kilter Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear all logged history?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { clearHistory() }
        } message: {
            Text("This permanently deletes your ascent log and sessions. It can't be undone.")
        }
    }

    private func clearHistory() {
        for e in entries { modelContext.delete(e) }
        for s in sessions { modelContext.delete(s) }
        try? modelContext.save()
    }
}
