import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The opt-in empty state shown when no lineup is installed (the `KilterCatalogSyncView` posture,
/// wireframe frame 2): Snappet ships no lineup data — **Download from Snappet Lineups** leads, with
/// importing a `.fpack` file as the power-user secondary (AirDrop / Files, exactly the Kilter
/// `.sqlite3` flow). QR / poster-scan / manual entry arrive with prompts 05–06.
struct FestivalEmptyStateView: View {
    let installer: FestivalLineupInstaller
    /// Presents the hosted-catalog browse sheet (owned by the root, which also hosts it non-empty).
    var onBrowse: () -> Void
    /// Presents the receive-only scanner (festival prompt 05) — a friend's shared plan / lineup QR.
    var onScan: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var showingImporter = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "music.mic")
                    .font(.system(size: 52))
                    .foregroundStyle(SnappetColor.festival)
                    .padding(.top, 24)

                Text("Get festival lineups")
                    .font(.title2.bold())

                Text("Snappet doesn't ship lineup data. Bring a festival onto this device once — "
                     + "then the whole weekend works offline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                statusView

                VStack(spacing: 12) {
                    Button { onBrowse() } label: {
                        Label("Download from Snappet Lineups", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installer.isWorking)
                    .accessibilityIdentifier("festival.catalog.browse")

                    Button { showingImporter = true } label: {
                        Label("Import pack file…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(installer.isWorking)
                    .accessibilityIdentifier("festival.catalog.import")

                    Button { onScan() } label: {
                        Label("Scan a friend's QR", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(installer.isWorking)
                    .accessibilityIdentifier("festival.scan")
                }

                privacyCard
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("festival.catalog.empty")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "fpack") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            Task { await installer.importPicked(result, into: context) }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch installer.phase {
        case .working(let fraction):
            VStack(spacing: 6) {
                ProgressView(value: fraction).progressViewStyle(.linear)
                Text("Installing…").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("festival.catalog.error")
        case .idle, .installed:
            EmptyView()
        }
    }

    /// The honest data-posture card (frame 2): community packs, one user-initiated GET, offline after.
    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("**Community packs, kept on-device.** Lineups are public schedule data; "
                     + "installing is one GET, and nothing is ever uploaded.")
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(SnappetColor.festival)
            }
            Label {
                Text("**Offline after install** — built for fields with no signal.")
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(SnappetColor.festival)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }
}

/// The hosted-catalog browse sheet (wireframe frame 3): the `music-festivals/` manifest rendered as
/// searchable rows with GET / progress / ✓ Installed states. Installing runs the one shared
/// installer funnel (fetch → decode → validate → store); the sheet stays up so the user can grab
/// the whole summer in one sitting.
struct FestivalCatalogBrowseView: View {
    let installer: FestivalLineupInstaller

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(SnappetCore.self) private var core
    @Query private var lineups: [FestivalLineup]

    @AppStorage("festival.catalog.host") private var host = festivalDefaultCatalogHost
    @State private var entries: [FestivalLineupEntry] = []
    @State private var loadFailure: String?
    @State private var loading = true
    @State private var query = ""
    @State private var year: String?

    private var installedPackIDs: Set<String> { Set(lineups.map(\.packID)) }
    private var filtered: [FestivalLineupEntry] { FestivalBrowse.filter(entries, query: query, year: year) }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack {
                        Spacer()
                        ProgressView("Loading lineups…")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let loadFailure {
                    failureSection(loadFailure)
                } else {
                    listContent
                }
                advancedSection
            }
            .searchable(text: $query, prompt: "Search festivals")
            .navigationTitle("Snappet Lineups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(installer.isWorking)
                        .accessibilityIdentifier("festival.browse.cancel")
                }
            }
            .task(id: host) { await loadManifest() }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var listContent: some View {
        let years = FestivalBrowse.years(in: entries)
        if years.count > 1 {
            Section {
                yearChips(years)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        Section {
            if filtered.isEmpty {
                Text(entries.isEmpty
                     ? "No lineups are published yet — check back closer to the season."
                     : "No festivals match that search.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { entry in
                row(for: entry)
            }
            if case .failed(let message) = installer.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("festival.browse.error")
            }
        } footer: {
            Text("Packs are tiny (a lineup is text). Install brings every stage — festivals "
                 + "work offline from then on.")
        }
    }

    private func yearChips(_ years: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(years, id: \.self) { y in
                    Button {
                        year = (year == y) ? nil : y
                    } label: {
                        Text(y)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(year == y ? AnyShapeStyle(SnappetColor.festival)
                                                  : AnyShapeStyle(SnappetColor.surfaceMuted),
                                        in: Capsule())
                            .foregroundStyle(year == y ? .white : SnappetColor.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("festival.browse.year.\(y)")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(for entry: FestivalLineupEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.mic")
                .font(.title3)
                .foregroundStyle(SnappetColor.festival)
                .frame(width: 40, height: 40)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(FestivalBrowse.metaLine(startDate: entry.startDate, endDate: entry.endDate,
                                             stages: entry.stages, sets: entry.sets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .installing(let fraction) = rowState(entry) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(SnappetColor.festival)
                }
            }
            Spacer(minLength: 8)
            trailing(for: entry)
        }
    }

    @ViewBuilder private func trailing(for entry: FestivalLineupEntry) -> some View {
        switch rowState(entry) {
        case .installing:
            EmptyView()   // the inline bar under the meta line carries progress
        case .installed:
            Label("Installed", systemImage: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(SnappetColor.perfFresh)
                .labelStyle(.titleAndIcon)
        case .get:
            Button("GET") { install(entry) }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
                .tint(SnappetColor.festival)
                .disabled(installer.isWorking)
                .accessibilityIdentifier("festival.browse.get.\(entry.id)")
        }
    }

    @ViewBuilder private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                TextField("Host URL", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.footnote)
                    .accessibilityIdentifier("festival.browse.host")
            }
        } footer: {
            Text("Snappet downloads from static files on a host you control — no accounts, "
                 + "nothing uploaded.")
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            VStack(spacing: 10) {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("festival.browse.loadError")
                Button("Try again") { Task { await loadManifest() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("festival.browse.retry")
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

    private func rowState(_ entry: FestivalLineupEntry) -> FestivalBrowseRowState {
        FestivalBrowse.rowState(entry: entry, installedPackIDs: installedPackIDs,
                                installingPackID: installer.installingPackID,
                                progress: installer.progress)
    }

    private func loadManifest() async {
        loading = true
        loadFailure = nil
        do {
            entries = try await FestivalCatalogClient(baseURL: host).manifest()
        } catch {
            loadFailure = "Couldn't reach Snappet Lineups. Check your connection and the host URL."
        }
        loading = false
    }

    private func install(_ entry: FestivalLineupEntry) {
        Task {
            let provider = HostedFestivalPackProvider(entry: entry, baseURL: host)
            if let lineup = await installer.install(using: provider, entryID: entry.id,
                                                    into: context) {
                core.log(module: FestivalModule.id, action: "install",
                         summary: "Installed lineup: \(lineup.name)",
                         metric: Double(lineup.setCount))
            }
        }
    }
}
