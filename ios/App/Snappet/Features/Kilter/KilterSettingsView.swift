import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Kilter preferences: the default board + angle that seed browsing, how grades render, the shared
/// heart-rate profile (#75 — the same app-global editor the workout tracker links to), the installed
/// climb catalog (status / refresh / remove — issue #42), and a destructive "clear logged history".
/// Pushed onto the App Library's shared NavigationStack from the catalog's More menu.
struct KilterSettingsView: View {
    let catalog: KilterCatalog
    @Environment(\.modelContext) private var modelContext
    /// For the heart-rate profile row (#75) — the profile is app-global (`AppModel.userProfile`),
    /// shared with the workout tracker, so this links to the same `UserHRProfileView` editor.
    @Environment(AppModel.self) private var app

    @AppStorage("kilter.layout") private var layoutId: Int = 1
    @AppStorage("kilter.angle") private var angle: Int = 40
    /// The user's physical board size (`product_size_id`) — drives which LED map is sent so the right
    /// holds light. Restored per layout via `KilterSizeMemory`; the layout default only seeds it.
    @AppStorage("kilter.productSizeId") private var productSizeId = 0
    @AppStorage("kilter.gradeFormat") private var gradeFormatRaw = KilterGradeFormat.both.rawValue
    @AppStorage("kilter.apiLevel") private var apiLevelRaw = KilterProtocol.APILevel.v3.rawValue
    /// P1: whether to suggest the usual board on arrival at a remembered coarse place (pre-connect).
    @AppStorage("kilter.suggestOnArrival") private var suggestOnArrival = true

    @Query private var entries: [KilterLogEntry]
    @Query private var sessions: [KilterSession]
    @State private var confirmingClear = false

    // P1 board detection (auto-detect a previously-connected board).
    @State private var boardMemory = KilterBoardMemory()
    /// Per-layout board-size memory — shared store with the root (both read/write the same
    /// `UserDefaults` map), so a size chosen here is what browsing restores and vice versa.
    @State private var sizeMemory = KilterSizeMemory()
    @State private var location = KilterLocationService()
    /// Bumped on rename / forget so the remembered-boards list re-renders (it reads off UserDefaults).
    @State private var boardsVersion = 0
    /// The board being renamed (drives the rename alert).
    @State private var renaming: (id: UUID, label: String)?
    @State private var renameText = ""

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
                let sizes = catalog.sizes(forLayout: layoutId)
                if sizes.count > 1 {
                    Picker("Board size", selection: $productSizeId) {
                        ForEach(sizes) { Text($0.label).tag($0.id) }
                    }
                    .accessibilityIdentifier("kilter.settings.boardSize")
                }
                Picker("Angle", selection: $angle) {
                    ForEach(catalog.angles(), id: \.self) { Text("\($0)°").tag($0) }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Used when you open the Kilter Board. Set your board size so the right holds light up.")
            }

            Section("Grades") {
                Picker("Show grades as", selection: $gradeFormatRaw) {
                    ForEach(KilterGradeFormat.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("kilter.settings.gradeFormat")
            }

            // The shared HR profile was only findable inside the workout tracker's settings, so
            // Kilter session summaries silently used the 190 bpm default ceiling (#75). Same
            // editor, second front door — the profile itself stays app-global.
            Section {
                NavigationLink {
                    UserHRProfileView()
                } label: {
                    LabeledContent("Heart-rate profile",
                                   value: app.userProfile.profile.resolvedMaxHR
                                       .map { "Max \(Int($0.rounded()))" } ?? "Not set")
                }
                .accessibilityIdentifier("kilter.settings.hrProfile")
            } header: {
                Text("Heart rate")
            } footer: {
                Text("Personalizes session heart-rate zones, % effort, and the calorie estimate. "
                     + "One profile for the whole app — without it, zones use a default 190 bpm ceiling.")
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

            // P1: auto-detect a previously-connected board (BLE recognition + optional on-device coarse
            // place suggestion). The location toggle skips CoreLocation entirely when off; BLE-only
            // recognition still works without it.
            Section {
                Toggle(isOn: $suggestOnArrival) {
                    Label("Suggest board on arrival", systemImage: "mappin.and.ellipse")
                }
                .accessibilityIdentifier("kilter.settings.suggestOnArrival")
                LabeledContent("Location") {
                    Text(locationStatusText).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("kilter.settings.locationStatus")
                if suggestOnArrival && location.authorization == .notDetermined && location.isSupported {
                    Button("Allow location while using the app") { location.requestIfNeeded() }
                        .accessibilityIdentifier("kilter.settings.requestLocation")
                }
            } header: {
                Text("Board detection")
            } footer: {
                Text("Snappet recognizes a board you've connected to before and restores its layout, "
                     + "size, and usual angle — you just confirm. Turn on location to suggest your usual "
                     + "board when you arrive at a remembered place; the match is made fully on your "
                     + "device and your location never leaves your phone.")
            }

            if !boardMemory.isEmpty {
                Section {
                    ForEach(boardMemory.rememberedSorted, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.board.label).font(.subheadline.weight(.medium))
                            Text(rememberedDetail(entry.board))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("kilter.settings.rememberedBoard")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                boardMemory.forget(identifier: entry.id); boardsVersion += 1
                            } label: { Label("Forget", systemImage: "trash") }
                            .accessibilityIdentifier("kilter.settings.forgetBoard")
                            Button {
                                renameText = entry.board.label
                                renaming = (id: entry.id, label: entry.board.label)
                            } label: { Label("Rename", systemImage: "pencil") }
                            .tint(.blue)
                            .accessibilityIdentifier("kilter.settings.renameBoard")
                        }
                    }
                } header: {
                    Text("Remembered boards")
                } footer: {
                    Text("Boards this device has connected to. Swipe to rename or forget — a forgotten "
                         + "board is re-learned the next time you connect to it.")
                }
                .id(boardsVersion)
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
        // Keep the board-size selection valid for the chosen layout (seed on open, restore on layout
        // change — never a blind reset; see syncBoardSize).
        .onAppear(perform: syncBoardSize)
        .onChange(of: layoutId) { syncBoardSize() }
        // Record a direct size pick for the chosen layout (idempotent with the root's identical hook).
        .onChange(of: productSizeId) { _, newSize in
            if catalog.sizes(forLayout: layoutId).contains(where: { $0.id == newSize }) {
                sizeMemory.remember(sizeId: newSize, forLayout: layoutId)
            }
        }
        .confirmationDialog("Clear all logged history?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { clearHistory() }
        } message: {
            Text("This permanently deletes your ascent log and sessions. It can't be undone.")
        }
        // P1: rename a remembered board.
        .alert("Rename board", isPresented: Binding(get: { renaming != nil },
                                                    set: { if !$0 { renaming = nil } }),
               presenting: renaming) { entry in
            TextField("Board name", text: $renameText)
                .accessibilityIdentifier("kilter.settings.renameField")
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { boardMemory.rename(identifier: entry.id, to: trimmed); boardsVersion += 1 }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Shown when this board is recognized and at your usual place.") }
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

    /// Resolve the size selection through the per-layout memory — the SAME rule the root runs, so the
    /// two screens can't disagree. Restores the chosen layout's remembered size, keeps a still-valid
    /// current one, else falls back to the layout default; does nothing while the catalog can't list
    /// sizes (the old reset here is one of the paths that stomped a chosen size back to the 12×14
    /// default — UX feedback "resets board to 12 x 14").
    private func syncBoardSize() {
        let ids = catalog.sizes(forLayout: layoutId).map(\.id)
        guard let pick = KilterSizeMemory.choose(remembered: sizeMemory.recall(forLayout: layoutId),
                                                 current: productSizeId, available: ids) else { return }
        if productSizeId != pick { productSizeId = pick }
        sizeMemory.remember(sizeId: pick, forLayout: layoutId)
    }

    /// Human-readable location authorization status for the Board-detection section.
    private var locationStatusText: String {
        switch location.authorization {
        case .authorized: return "While using the app"
        case .denied: return "Off — using Bluetooth only"
        case .notDetermined: return "Not set"
        }
    }

    /// "<size> · <angle>° · last seen <date>" detail line for a remembered board.
    private func rememberedDetail(_ board: RememberedBoard) -> String {
        let layoutName = catalog.layouts().first { $0.id == board.layoutId }?.name
        let sizeId = catalog.effectiveSizeId(forLayout: board.layoutId, requested: board.productSizeId)
        let sizeName = catalog.sizes(forLayout: board.layoutId).first { $0.id == sizeId }?.name
        let angle = board.usualAngle.map { "\($0)°" }
        let seen = "Seen " + board.lastSeen.formatted(date: .abbreviated, time: .omitted)
        return [layoutName, sizeName, angle, seen].compactMap { $0 }.joined(separator: " · ")
    }

    private func clearHistory() {
        // Preserve the in-flight session (and its entries) so a live/recovered session isn't deleted
        // out from under the catalog's session bar — clear everything else.
        let activeID = sessions.first { $0.isActive }?.id
        for e in entries where e.sessionId != activeID { modelContext.delete(e) }
        for s in sessions where !s.isActive { modelContext.delete(s) }
        try? modelContext.save()
    }
}
