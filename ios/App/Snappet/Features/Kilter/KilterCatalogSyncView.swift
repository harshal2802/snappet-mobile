import SwiftUI
import UniformTypeIdentifiers

/// The opt-in empty state shown when no catalog is installed (issue #42). Snappet ships no Aurora data;
/// the user brings the climb catalog onto this device once — **Download from Kilter** leads (pick your
/// board + size; issue #75, mirroring Android #94), with importing a `.sqlite3` file as the power-user
/// secondary — and from then on everything browse/detail/log/illuminate works offline.
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
                    // Download leads (issue #75, mirroring Android #94): it's the only path most
                    // phone users can act on. The sheet picks your board + size; the dataset is a
                    // user-hosted static file — see KilterAuroraSync.swift for the legal posture
                    // (ToU notice + user-controlled host, unchanged by this emphasis reversal).
                    Button { showingSync = true } label: {
                        Label("Download from Kilter…", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                    .accessibilityIdentifier("kilter.catalog.sync")

                    // Power-user path: install a catalog .sqlite3 you already have (Files).
                    Button { showingImporter = true } label: {
                        Label("Import catalog file…", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("kilter.catalog.import")
                }

                Text("Download fetches the catalog for your board from a hosted dataset and trims it "
                     + "on this device. Import installs a catalog file you already have.")
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
                    let provider = HostedCatalogProvider(board: board, filter: filter, baseURL: host,
                                                         name: KilterCatalogDownloadSheet.name(for: filter))
                    await installer.install(using: provider)
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

/// Static Kilter option lists for the download sheet (the dataset isn't loaded until after download, so
/// these can't come from the DB). Only Kilter Original (1) + Homewall (8) are supported today; the rest
/// are shown struck-through as future work. Grades/angles are the standard Kilter scale.
enum KilterCatalogOptions {
    static let layouts: [(id: Int, name: String, supported: Bool)] = [
        (1, "Original", true), (8, "Homewall", true),
        (2, "JUUL", false), (3, "Standard Medium", false), (4, "BKB Level 1", false),
        (5, "Spire", false), (6, "Tycho Complete", false), (7, "Tycho 2020", false),
    ]
    static let angles = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70]
    /// `difficulty_grades.difficulty` int → label (the listed Kilter grades).
    static let grades: [(difficulty: Int, label: String)] = [
        (10, "4a / V0"), (11, "4b / V0"), (12, "4c / V0"), (13, "5a / V1"), (14, "5b / V1"),
        (15, "5c / V2"), (16, "6a / V3"), (17, "6a+ / V3"), (18, "6b / V4"), (19, "6b+ / V4"),
        (20, "6c / V5"), (21, "6c+ / V5"), (22, "7a / V6"), (23, "7a+ / V7"), (24, "7b / V8"),
        (25, "7b+ / V8"), (26, "7c / V9"), (27, "7c+ / V10"), (28, "8a / V11"), (29, "8a+ / V12"),
        (30, "8b / V13"), (31, "8b+ / V14"), (32, "8c / V15"), (33, "8c+ / V16"),
    ]
    static func gradeLabel(_ d: Int) -> String { grades.first { $0.difficulty == d }?.label ?? "—" }

    /// The two supported Kilter boards + their listed sizes, with each size's fit box (hole units, from
    /// the real Aurora `product_sizes.edge_*`). Embedded because the dataset isn't installed on a first
    /// download — board *dimensions* are structural reference (like the layout ids), not climb data (#42).
    /// Homewall ships each size under several LED-kit ids; we keep one per physical size (the box drives
    /// the download fit filter, not the id).
    static let boards: [KilterKnownBoard] = [
        KilterKnownBoard(layoutId: 1, name: "Kilter Original", defaultSizeId: 10, sizes: [
            KilterKnownSize(id: 14, name: "7 × 10", box: KilterSizeBox(left: 28, right: 116, bottom: 36, top: 156)),
            KilterKnownSize(id: 8,  name: "8 × 12", box: KilterSizeBox(left: 24, right: 120, bottom: 0,  top: 156)),
            KilterKnownSize(id: 10, name: "12 × 12 (with kickboard)", box: KilterSizeBox(left: 0, right: 144, bottom: 0,  top: 156)),
            KilterKnownSize(id: 27, name: "12 × 12 (no kickboard)",   box: KilterSizeBox(left: 0, right: 144, bottom: 12, top: 156)),
            KilterKnownSize(id: 7,  name: "12 × 14", box: KilterSizeBox(left: 0, right: 144, bottom: 0, top: 180)),
            KilterKnownSize(id: 28, name: "16 × 12", box: KilterSizeBox(left: -24, right: 168, bottom: 0, top: 156)),
        ]),
        KilterKnownBoard(layoutId: 8, name: "Kilter Homewall", defaultSizeId: 25, sizes: [
            KilterKnownSize(id: 17, name: "7 × 10",  box: KilterSizeBox(left: -44, right: 44, bottom: 24,  top: 144)),
            KilterKnownSize(id: 23, name: "8 × 12",  box: KilterSizeBox(left: -44, right: 44, bottom: -12, top: 144)),
            KilterKnownSize(id: 21, name: "10 × 10", box: KilterSizeBox(left: -56, right: 56, bottom: 24,  top: 144)),
            KilterKnownSize(id: 25, name: "10 × 12", box: KilterSizeBox(left: -56, right: 56, bottom: -12, top: 144)),
        ]),
    ]
    static func board(_ layoutId: Int) -> KilterKnownBoard { boards.first { $0.layoutId == layoutId } ?? boards[0] }
    /// A human label for a chosen `(layout, size)` — for the installed-catalog name.
    static func sizeName(layoutId: Int, sizeId: Int) -> String? {
        board(layoutId).sizes.first { $0.id == sizeId }?.name
    }
}

/// One physical Kilter board size: its `product_size_id`, a label, and its fit box (used to keep only
/// the climbs that fit it at download time).
struct KilterKnownSize: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let box: KilterSizeBox
}

/// A Kilter board the user can own — a layout + its sizes. Drives the download sheet's board picker.
struct KilterKnownBoard: Identifiable, Hashable, Sendable {
    let layoutId: Int
    let name: String
    /// Seeded size when the user first picks this board (a common one); they change it to theirs.
    let defaultSizeId: Int
    let sizes: [KilterKnownSize]
    var id: Int { layoutId }
}

/// Sheet for the in-app catalog download — reshaped around the one thing an end user actually knows:
/// **which board do you have.** Pick your layout (Original / Homewall) + your size, choose how many
/// climbs, download. Everything else (angle, grade, quality, …) is a *browse-time* filter in the
/// installed catalog, not a download choice. The dataset is a static file the user hosts; no accounts.
/// See `KilterAuroraSync.swift` for the legal posture (personal/sideload use).
struct KilterCatalogDownloadSheet: View {
    let installer: KilterCatalogInstaller
    /// Called when the user taps Download — the host runs the install and dismisses on success.
    var onSubmit: (CatalogBoardEntry, CatalogFilter, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("kilter.dl.host") private var host = kilterDefaultCatalogHost
    /// The user's board — a layout (Original 1 / Homewall 8) + a size (`product_size_id`). These two,
    /// your physical board, are the **only** download filters; the rest are browse-time in the list.
    @AppStorage("kilter.dl.layout") private var layoutId = 1
    @AppStorage("kilter.dl.sizeId") private var sizeId = 10   // seeded to a common Original size
    @AppStorage("kilter.dl.maxClimbs") private var maxClimbs = 2000
    @AppStorage("kilter.dl.showAdvanced") private var showAdvanced = false

    @State private var boards: [CatalogBoardEntry] = []
    @State private var loadingBoards = true

    /// "How many climbs to keep" presets — the source is one ~80 MB file, so this caps the *installed* size.
    private static let caps = [1000, 2000, 5000, 10000, 0]   // 0 = everything that fits

    private var currentBoard: KilterKnownBoard { KilterCatalogOptions.board(layoutId) }
    private var selectedSize: KilterKnownSize? { currentBoard.sizes.first { $0.id == sizeId } }
    private var kilterBoard: CatalogBoardEntry? { boards.first { $0.board == "kilter" } ?? boards.first }
    private var isWorking: Bool { if case .working = installer.phase { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Form {
                boardSection
                catalogSizeSection
                actionSection
                advancedSection
            }
            .navigationTitle("Get climbs")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
            }
            .onAppear(perform: syncSize)
            // Keep the size valid for the chosen board (seed the board's default on a layout switch).
            .onChange(of: layoutId) { syncSize() }
            .task(id: host) {
                loadingBoards = true
                boards = await HostedCatalogClient(baseURL: host).importableBoards()
                loadingBoards = false
            }
        }
    }

    // MARK: - Sections

    /// "Your board": the layout + size — the only two download filters (your physical board).
    @ViewBuilder private var boardSection: some View {
        Section {
            Picker("Board", selection: $layoutId) {
                ForEach(KilterCatalogOptions.boards) { Text($0.name).tag($0.layoutId) }
            }
            .accessibilityIdentifier("kilter.dl.layout")
            Picker("Size", selection: $sizeId) {
                ForEach(currentBoard.sizes) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("kilter.dl.size")
        } header: {
            Text("Your board")
        } footer: {
            Text("Pick the Kilter board you climb on — we'll get the climbs that fit it. The size is "
                 + "printed on the board (and shown in the official Kilter app).")
        }
    }

    /// "How many climbs" — a friendly cap on the *installed* catalog (the source download is one file).
    @ViewBuilder private var catalogSizeSection: some View {
        Section {
            Picker("Climbs to keep", selection: $maxClimbs) {
                ForEach(Self.caps, id: \.self) {
                    Text($0 == 0 ? "Everything that fits" : "Most popular \($0.formatted())").tag($0)
                }
            }
            .accessibilityIdentifier("kilter.dl.cap")
        } header: {
            Text("How many climbs")
        } footer: {
            Text("More climbs = a bigger download. Once installed, filter by grade, angle, quality and "
                 + "more right in the list.")
        }
    }

    @ViewBuilder private var actionSection: some View {
        Section {
            switch installer.phase {
            case .working(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                    Text(fraction < 0.75 ? "Downloading… \(Int(fraction / 0.75 * 100))%"
                         : fraction < 1 ? "Trimming to your board…" : "Installing…")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("kilter.dl.error")
            default:
                if let b = kilterBoard, b.climbs > 0 {
                    Text("\(b.climbs.formatted()) climbs available to choose from.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                guard let board = kilterBoard else { return }
                onSubmit(board, buildFilter(), host)
            } label: {
                Label("Download", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || kilterBoard == nil || selectedSize == nil)
            .accessibilityIdentifier("kilter.dl.download")
        }
    }

    /// Advanced (collapsed): the host URL — most users never touch it.
    @ViewBuilder private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("Host URL", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.footnote).accessibilityIdentifier("kilter.dl.host")
            }
        } footer: {
            Text("Snappet downloads from a static file you host — no Kilter account, nothing uploaded.")
        }
    }

    // MARK: - Filter assembly

    /// Snap the size to one this board offers (seed the board's default when the layout changes / is stale).
    private func syncSize() {
        if !currentBoard.sizes.contains(where: { $0.id == sizeId }) { sizeId = currentBoard.defaultSizeId }
    }

    /// The download keeps only this board's climbs (layout + size fit). Listed + single-frame stay on as
    /// sensible mobile defaults; angle/grade/quality/etc. are browse-time, so they're left unset here.
    private func buildFilter() -> CatalogFilter {
        var f = CatalogFilter()
        f.layoutIds = [layoutId]
        if let size = selectedSize { f.sizeId = size.id; f.sizeBox = size.box }
        f.maxClimbs = maxClimbs
        return f
    }

    /// A short library name for the Settings catalog list, e.g. "Kilter · Original · 12 × 14 · top 2000".
    static func name(for f: CatalogFilter) -> String {
        var parts = ["Kilter"]
        if let layout = f.layoutIds.first {
            parts.append(KilterCatalogOptions.board(layout).name.replacingOccurrences(of: "Kilter ", with: ""))
            if let sizeId = f.sizeId, let size = KilterCatalogOptions.sizeName(layoutId: layout, sizeId: sizeId) {
                parts.append(size)
            }
        }
        parts.append(f.maxClimbs == 0 ? "all" : "top \(f.maxClimbs)")
        return parts.joined(separator: " · ")
    }
}
