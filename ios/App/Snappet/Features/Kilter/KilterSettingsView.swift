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

    // Catalog library management (download / import / switch active / remove).
    @State private var installer = KilterCatalogInstaller()
    @State private var showingImporter = false
    @State private var showingDownload = false
    /// Bumped on activate/remove so the library list re-renders (the store reads off the filesystem).
    @State private var libraryVersion = 0

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
                let catalogs = installer.catalogs
                let activeId = installer.activeCatalogId
                if catalogs.isEmpty {
                    Text("No catalog installed").foregroundStyle(.secondary)
                } else {
                    ForEach(catalogs) { c in
                        Button {
                            if c.id != activeId { installer.activate(id: c.id); libraryVersion += 1 }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: c.id == activeId ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(c.id == activeId ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.displayName).font(.subheadline.weight(.medium))
                                    Text("\(c.meta.climbCount) climbs · "
                                        + ByteCountFormatter.string(fromByteCount: c.meta.sizeBytes, countStyle: .file)
                                        + " · " + c.meta.installedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) { installer.remove(id: c.id); libraryVersion += 1 }
                        }
                    }
                }
                Button("Download from Kilter…") { showingDownload = true }
                    .accessibilityIdentifier("kilter.settings.download")
                Button("Import file…") { showingImporter = true }
                    .accessibilityIdentifier("kilter.settings.import")
                if case .failed(let message) = installer.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Downloaded catalogs")
            } footer: {
                Text("Snappet doesn't ship Kilter's catalog — it lives only on this device. Tap one to make "
                     + "it active, swipe to remove. Removing keeps your logged ascents and saved climbs.")
            }
            .id(libraryVersion)

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
            Task { await installer.importPicked(result); libraryVersion += 1 }
        }
        .sheet(isPresented: $showingDownload) {
            KilterCatalogDownloadSheet(installer: installer) { board, filter, host in
                Task {
                    let provider = HostedCatalogProvider(board: board, filter: filter, baseURL: host,
                                                         name: KilterCatalogDownloadSheet.name(for: filter))
                    await installer.install(using: provider)
                    if case .installed = installer.phase { showingDownload = false; libraryVersion += 1 }
                }
            }
        }
    }

    private func clearHistory() {
        for e in entries { modelContext.delete(e) }
        for s in sessions { modelContext.delete(s) }
        try? modelContext.save()
    }
}
