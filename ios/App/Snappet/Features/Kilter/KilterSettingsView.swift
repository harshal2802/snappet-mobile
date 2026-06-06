import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Kilter preferences: the default board + angle that seed browsing, how grades render, the installed
/// climb catalog (status / refresh / remove — issue #42), and a destructive "clear logged history".
/// Pushed onto the App Library's shared NavigationStack from the catalog's More menu.
struct KilterSettingsView: View {
    let catalog: KilterCatalog
    @Environment(\.modelContext) private var modelContext

    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.angle") private var angle: Int = 40
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue

    @Query private var entries: [KilterLogEntry]
    @Query private var sessions: [KilterSession]
    @State private var confirmingClear = false

    // Catalog management (install / refresh / remove the on-device catalog).
    @State private var installer = KilterCatalogInstaller()
    @State private var showingImporter = false
    @State private var confirmingRemove = false

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
                if let meta = installer.metadata {
                    LabeledContent("Climbs", value: "\(meta.climbCount)")
                    LabeledContent("Size",
                        value: ByteCountFormatter.string(fromByteCount: meta.sizeBytes, countStyle: .file))
                    LabeledContent("Version") {
                        Text(meta.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Button("Refresh catalog…") { showingImporter = true }
                        .accessibilityIdentifier("kilter.settings.refreshCatalog")
                    Button("Remove downloaded catalog", role: .destructive) { confirmingRemove = true }
                        .accessibilityIdentifier("kilter.settings.removeCatalog")
                } else {
                    Text("No catalog installed").foregroundStyle(.secondary)
                    Button("Get the catalog…") { showingImporter = true }
                        .accessibilityIdentifier("kilter.settings.getCatalog")
                }
                if case .failed(let message) = installer.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Climb catalog")
            } footer: {
                Text("Snappet doesn't ship Kilter's catalog — it lives only on this device. Removing it "
                     + "keeps your logged ascents and saved climbs.")
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
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "sqlite3") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            Task { await installer.importPicked(result) }
        }
        .alert("Remove downloaded catalog?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { installer.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The climb catalog will be deleted from this device. Your logged ascents and saved "
                 + "climbs are kept — you can import it again anytime.")
        }
    }

    private func clearHistory() {
        for e in entries { modelContext.delete(e) }
        for s in sessions { modelContext.delete(s) }
        try? modelContext.save()
    }
}
