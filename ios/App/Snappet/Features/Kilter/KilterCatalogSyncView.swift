import SwiftUI
import UniformTypeIdentifiers

/// The opt-in empty state shown when no catalog is installed (issue #42). Snappet ships no Aurora data;
/// the user brings the climb catalog onto this device once — by importing a `.sqlite3` they built
/// themselves (Phase 1) — and from then on everything browse/detail/log/illuminate works offline.
///
/// Surfaces Aurora's Terms of Use + a link before any fetch, and makes clear the data stays on-device.
struct KilterCatalogSyncView: View {
    /// Called after a successful install so the host can reload the reader.
    var onInstalled: () -> Void = {}

    @State private var installer = KilterCatalogInstaller()
    @State private var showingImporter = false
    @State private var showingSync = false

    private let auroraTermsURL = URL(string: "https://kilterboardapp.com/terms-of-use")!

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 52))
                    .foregroundStyle(SnappetColor.moduleAccent("kilter"))
                    .padding(.top, 24)

                Text("Get the climb catalog")
                    .font(.title2.bold())

                Text("Snappet doesn't ship Kilter's climb catalog. Bring it onto this device once, then "
                     + "browse, log, and illuminate offline from then on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                termsCard

                statusView

                VStack(spacing: 12) {
                    Button { showingImporter = true } label: {
                        Label("Import catalog file…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                    .accessibilityIdentifier("kilter.catalog.import")

                    // Phase 2 (AuroraSyncProvider): download straight from Aurora's servers. Opens a
                    // sheet for the board + optional account credentials. Personal/sideload use only —
                    // see KilterAuroraSync.swift for the legal posture.
                    Button { showingSync = true } label: {
                        Label("Download from Kilter…", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("kilter.catalog.sync")
                }

                Text("Download fetches the catalog from the board's servers (your account is optional). "
                     + "Or build a file yourself with the boardlib tool — see tools/kilter.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("kilter.catalog.sync.empty")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "sqlite3") ?? .data, .data],
                      allowsMultipleSelection: false) { result in
            Task {
                await installer.importPicked(result)
                if case .installed = installer.phase { onInstalled() }
            }
        }
        .sheet(isPresented: $showingSync) {
            KilterCatalogDownloadSheet(installer: installer) { board, filter, host in
                Task {
                    await installer.install(using: HostedCatalogProvider(board: board, filter: filter, baseURL: host))
                    if case .installed = installer.phase { showingSync = false; onInstalled() }
                }
            }
        }
    }

    private var isWorking: Bool { if case .working = installer.phase { return true } else { return false } }

    private var termsCard: some View {
        VStack(spacing: 6) {
            Text("The catalog is Aurora Climbing's data, governed by their Terms of Use. It stays on "
                 + "this device — Snappet never uploads it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link(destination: auroraTermsURL) {
                Label("Aurora Climbing Terms of Use", systemImage: "link").font(.footnote)
            }
            .accessibilityIdentifier("kilter.catalog.terms")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var statusView: some View {
        switch installer.phase {
        case .working(let fraction):
            VStack(spacing: 6) {
                ProgressView(value: fraction).progressViewStyle(.linear)
                Text(fraction < 1 ? "Getting catalog…" : "Installing…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("kilter.catalog.error")
        case .idle, .installed:
            EmptyView()
        }
    }
}

/// Sheet for the in-app catalog download: pick a board (from the host's manifest) + filters, then fetch
/// the gzipped dataset and trim it on-device to an importable catalog. No accounts/credentials — the
/// dataset is a static file the user hosts. Progress + errors read from the shared `installer`. See
/// `KilterAuroraSync.swift` for the legal posture (personal/sideload use).
struct KilterCatalogDownloadSheet: View {
    let installer: KilterCatalogInstaller
    /// Called when the user taps Download — the host runs the install and dismisses on success.
    var onSubmit: (CatalogBoardEntry, CatalogFilter, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("kilter.dl.host") private var host = kilterDefaultCatalogHost
    @AppStorage("kilter.dl.board") private var boardKey = "kilter"
    @AppStorage("kilter.dl.maxClimbs") private var maxClimbs = 2000
    @AppStorage("kilter.dl.kilterLayoutsOnly") private var kilterLayoutsOnly = true
    @AppStorage("kilter.dl.benchmarksOnly") private var benchmarksOnly = false

    @State private var boards: [CatalogBoardEntry] = []
    @State private var loadingBoards = true

    private static let caps = [1000, 2000, 5000, 10000]

    private var selectedBoard: CatalogBoardEntry? {
        boards.first { $0.board == boardKey } ?? boards.first
    }
    private var isWorking: Bool { if case .working = installer.phase { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Board") {
                    if loadingBoards {
                        HStack { ProgressView(); Text("Loading boards…").foregroundStyle(.secondary) }
                    } else if boards.isEmpty {
                        Text("Couldn't load boards from the host.").foregroundStyle(.secondary)
                    } else {
                        Picker("Board", selection: $boardKey) {
                            ForEach(boards) { Text($0.label).tag($0.board) }
                        }
                        .accessibilityIdentifier("kilter.dl.board")
                        if let b = selectedBoard {
                            LabeledContent("Climbs available", value: b.climbs > 0 ? b.climbs.formatted() : "—")
                                .font(.footnote)
                        }
                    }
                }

                Section {
                    Picker("Keep most-climbed", selection: $maxClimbs) {
                        ForEach(Self.caps, id: \.self) { Text("Top \($0.formatted())").tag($0) }
                    }
                    .accessibilityIdentifier("kilter.dl.cap")
                    Toggle("Kilter layouts only", isOn: $kilterLayoutsOnly)
                    Toggle("Benchmarks (classics) only", isOn: $benchmarksOnly)
                } header: {
                    Text("Filters")
                } footer: {
                    Text("The full dataset is ~80 MB to download; it's trimmed on-device to the filters "
                         + "above so the installed catalog stays small. More filters live in the web "
                         + "Board Explorer.")
                }

                Section {
                    switch installer.phase {
                    case .working(let fraction):
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: fraction).progressViewStyle(.linear)
                            Text(fraction < 0.75 ? "Downloading… \(Int(fraction / 0.75 * 100))%"
                                 : fraction < 1 ? "Trimming to your filters…" : "Installing…")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("kilter.dl.error")
                    default:
                        EmptyView()
                    }

                    Button {
                        guard let board = selectedBoard else { return }
                        var filter = CatalogFilter()
                        filter.maxClimbs = maxClimbs
                        filter.layoutIds = kilterLayoutsOnly ? [1, 8] : []
                        filter.benchmarkOnly = benchmarksOnly
                        onSubmit(board, filter, host)
                    } label: {
                        Label("Download catalog", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || selectedBoard == nil)
                    .accessibilityIdentifier("kilter.dl.download")
                }

                Section("Source") {
                    TextField("Host URL", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                        .accessibilityIdentifier("kilter.dl.host")
                }
            }
            .navigationTitle("Download catalog")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
            }
            .task(id: host) {
                loadingBoards = true
                boards = await HostedCatalogClient(baseURL: host).importableBoards()
                if !boards.contains(where: { $0.board == boardKey }) { boardKey = boards.first?.board ?? "kilter" }
                loadingBoards = false
            }
        }
    }
}
