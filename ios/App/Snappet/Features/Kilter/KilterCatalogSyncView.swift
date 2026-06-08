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
}

/// Sheet for the in-app catalog download: pick a board + the full Board-Explorer filter set, then fetch
/// the gzipped dataset and trim it on-device to an importable catalog. No accounts — the dataset is a
/// static file the user hosts. Only Kilter Original + Homewall are buildable today; other boards/layouts
/// show struck-through. Progress + errors read from the shared `installer`. See `KilterAuroraSync.swift`
/// for the legal posture (personal/sideload use).
struct KilterCatalogDownloadSheet: View {
    let installer: KilterCatalogInstaller
    /// Called when the user taps Download — the host runs the install and dismisses on success.
    var onSubmit: (CatalogBoardEntry, CatalogFilter, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("kilter.dl.host") private var host = kilterDefaultCatalogHost
    @AppStorage("kilter.dl.includeOriginal") private var includeOriginal = true
    @AppStorage("kilter.dl.includeHomewall") private var includeHomewall = true
    @AppStorage("kilter.dl.angle") private var angle = -1          // -1 = any
    @AppStorage("kilter.dl.gradeMin") private var gradeMin = 0     // 0 = any
    @AppStorage("kilter.dl.gradeMax") private var gradeMax = 0
    @AppStorage("kilter.dl.minAscents") private var minAscents = 0
    @AppStorage("kilter.dl.minQuality") private var minQuality = 0.0
    @AppStorage("kilter.dl.setter") private var setter = ""
    @AppStorage("kilter.dl.name") private var nameContains = ""
    @AppStorage("kilter.dl.benchmarksOnly") private var benchmarksOnly = false
    @AppStorage("kilter.dl.listedOnly") private var listedOnly = true
    @AppStorage("kilter.dl.singleFrameOnly") private var singleFrameOnly = true
    @AppStorage("kilter.dl.maxClimbs") private var maxClimbs = 2000
    /// Board-size filter (`product_size_id`); 0 = any size. Keep only climbs that fit the chosen board.
    @AppStorage("kilter.dl.sizeId") private var dlSizeId = 0

    @State private var boards: [CatalogBoardEntry] = []
    @State private var loadingBoards = true

    private let catalog = KilterCatalog.shared
    /// Sizes offered in the size filter — read from the **installed** catalog (with a fit box), deduped
    /// across the downloaded layouts. Empty (and the section hidden) on a first-ever download, since the
    /// board's sizes aren't known until a catalog exists. The chosen size's box drives the fit filter.
    private var installedSizes: [KilterBoardSize] {
        guard catalog.isAvailable else { return [] }
        var seen = Set<Int>()
        return [1, 8].flatMap { catalog.sizes(forLayout: $0) }
            .filter { $0.box != nil && seen.insert($0.id).inserted }
    }

    private static let caps = [1000, 2000, 5000, 10000, 0]   // 0 = all matching
    private static let ascentChoices = [0, 10, 50, 100, 500, 1000]

    /// The Kilter board entry (the only importable one today), if the host listed it.
    private var kilterBoard: CatalogBoardEntry? { boards.first { $0.board == "kilter" } ?? boards.first }
    private var hasLayout: Bool { includeOriginal || includeHomewall }
    private var isWorking: Bool { if case .working = installer.phase { return true } else { return false } }

    var body: some View {
        NavigationStack {
            Form {
                boardSection
                layoutSection
                filterSection
                boardSizeSection
                sizeSection
                actionSection
                Section("Source") {
                    TextField("Host URL", text: $host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote).accessibilityIdentifier("kilter.dl.host")
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
                loadingBoards = false
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var boardSection: some View {
        Section {
            if loadingBoards {
                HStack { ProgressView(); Text("Loading boards…").foregroundStyle(.secondary) }
            } else {
                // Kilter is the only importable board today; show it selected and any other manifest
                // boards struck-through as future work.
                Label("Kilter Board", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
                if let b = kilterBoard, b.climbs > 0 {
                    LabeledContent("Climbs available", value: b.climbs.formatted()).font(.footnote)
                }
                ForEach(boards.filter { $0.board != "kilter" }) { b in
                    Text(b.label).strikethrough().foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Board")
        } footer: {
            Text("Only the Kilter Board is supported right now.")
        }
    }

    @ViewBuilder private var layoutSection: some View {
        Section {
            Toggle("Original", isOn: $includeOriginal).accessibilityIdentifier("kilter.dl.layout.original")
            Toggle("Homewall", isOn: $includeHomewall).accessibilityIdentifier("kilter.dl.layout.homewall")
            ForEach(KilterCatalogOptions.layouts.filter { !$0.supported }, id: \.id) { l in
                Text(l.name).strikethrough().foregroundStyle(.tertiary)
            }
        } header: {
            Text("Layouts")
        } footer: {
            Text(hasLayout ? "Other layouts are coming later."
                 : "Pick at least one layout to download.")
        }
    }

    @ViewBuilder private var filterSection: some View {
        Section("Filters") {
            Picker("Angle", selection: $angle) {
                Text("Any").tag(-1)
                ForEach(KilterCatalogOptions.angles, id: \.self) { Text("\($0)°").tag($0) }
            }
            Picker("Min grade", selection: $gradeMin) {
                Text("Any").tag(0)
                ForEach(KilterCatalogOptions.grades, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
            }
            .onChange(of: gradeMin) { _, lo in if gradeMax != 0 && lo > gradeMax { gradeMax = lo } }
            Picker("Max grade", selection: $gradeMax) {
                Text("Any").tag(0)
                ForEach(KilterCatalogOptions.grades, id: \.difficulty) { Text($0.label).tag($0.difficulty) }
            }
            .onChange(of: gradeMax) { _, hi in if hi != 0 && hi < gradeMin { gradeMin = hi } }
            Picker("Min ascents", selection: $minAscents) {
                ForEach(Self.ascentChoices, id: \.self) { Text($0 == 0 ? "Any" : "\($0)+").tag($0) }
            }
            Picker("Min quality", selection: $minQuality) {
                Text("Any").tag(0.0); Text("★ 1+").tag(1.0); Text("★ 2+").tag(2.0); Text("★ 3").tag(3.0)
            }
            TextField("Setter contains", text: $setter)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Name contains", text: $nameContains)
            Toggle("Benchmarks (classics) only", isOn: $benchmarksOnly)
            Toggle("Listed only", isOn: $listedOnly)
            Toggle("Single-frame only", isOn: $singleFrameOnly)
        }
    }

    /// Board-size filter — only shown when the installed catalog can supply sizes (with fit boxes).
    @ViewBuilder private var boardSizeSection: some View {
        let sizes = installedSizes
        if !sizes.isEmpty {
            Section {
                Picker("Board size", selection: $dlSizeId) {
                    Text("Any size").tag(0)
                    ForEach(sizes) { Text($0.label).tag($0.id) }
                }
                .accessibilityIdentifier("kilter.dl.size")
            } header: {
                Text("Board size")
            } footer: {
                Text("Keep only climbs that physically fit this board size (mirrors the Board Explorer).")
            }
        }
    }

    @ViewBuilder private var sizeSection: some View {
        Section {
            Picker("Keep most-climbed", selection: $maxClimbs) {
                ForEach(Self.caps, id: \.self) { Text($0 == 0 ? "All matching" : "Top \($0.formatted())").tag($0) }
            }
            .accessibilityIdentifier("kilter.dl.cap")
        } header: {
            Text("Catalog size")
        } footer: {
            Text("The full dataset is ~80 MB to download; it's trimmed on-device to the filters above so "
                 + "the installed catalog stays small.")
        }
    }

    @ViewBuilder private var actionSection: some View {
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
                guard let board = kilterBoard else { return }
                onSubmit(board, buildFilter(), host)
            } label: {
                Label("Download catalog", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || kilterBoard == nil || !hasLayout)
            .accessibilityIdentifier("kilter.dl.download")
        }
    }

    // MARK: - Filter assembly

    private func buildFilter() -> CatalogFilter {
        var f = CatalogFilter()
        f.layoutIds = [includeOriginal ? 1 : nil, includeHomewall ? 8 : nil].compactMap { $0 }
        f.angle = angle >= 0 ? angle : nil
        f.gradeMin = gradeMin > 0 ? gradeMin : nil
        f.gradeMax = gradeMax > 0 ? gradeMax : nil
        f.minAscents = minAscents > 0 ? minAscents : nil
        f.minQuality = minQuality > 0 ? minQuality : nil
        f.setter = setter
        f.name = nameContains
        f.benchmarkOnly = benchmarksOnly
        f.listedOnly = listedOnly
        f.singleFrameOnly = singleFrameOnly
        f.maxClimbs = maxClimbs
        // Only apply the size filter when the chosen size resolves to a fit box from the installed catalog.
        if dlSizeId > 0, let box = installedSizes.first(where: { $0.id == dlSizeId })?.box {
            f.sizeId = dlSizeId
            f.sizeBox = box
        }
        return f
    }

    /// A short library name from the active filters (shown in the Settings catalog list).
    static func name(for f: CatalogFilter) -> String {
        var parts = ["Kilter"]
        let layouts = [f.layoutIds.contains(1) ? "Original" : nil,
                       f.layoutIds.contains(8) ? "Homewall" : nil].compactMap { $0 }
        if !layouts.isEmpty { parts.append(layouts.joined(separator: "+")) }
        if let a = f.angle { parts.append("\(a)°") }
        if f.gradeMin != nil || f.gradeMax != nil {
            let lo = f.gradeMin.map(KilterCatalogOptions.gradeLabel) ?? "any"
            let hi = f.gradeMax.map(KilterCatalogOptions.gradeLabel) ?? "any"
            parts.append("\(lo)–\(hi)")
        }
        if f.benchmarkOnly { parts.append("classics") }
        parts.append(f.maxClimbs == 0 ? "all" : "top \(f.maxClimbs)")
        return parts.joined(separator: " · ")
    }
}
