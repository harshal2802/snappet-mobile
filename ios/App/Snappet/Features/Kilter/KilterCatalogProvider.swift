import Foundation

/// The network/IO edge for getting a catalog onto the device. Everything else in the Kilter module is
/// read-only and source-agnostic; this protocol is the **only** place a catalog's bytes are produced,
/// so the read path never cares where they came from.
///
/// A provider just yields a local `.sqlite3` file already on this device. The caller
/// (`KilterCatalogInstaller`) validates it (`KilterCatalogValidator`) and installs it
/// (`KilterCatalogStore`) — so validation/installation is identical for every source.
protocol KilterCatalogProvider: Sendable {
    /// Shown on the button that triggers this provider.
    var displayName: String { get }
    /// Produce a catalog file on local disk. `progress` is 0…1 (best-effort).
    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// **Phase 1 — the shipped path.** The user supplies a `.sqlite3` they built/exported themselves
/// (Files picker on iOS / SAF on Android) — e.g. with the `tools/kilter/build_bundled_db.py` tool.
/// We copy the picked file onto our own temp volume and hand it back; **nothing is fetched from a
/// network**, which is the cleanest legal posture: Snappet never touches Aurora's servers, the user
/// brings their own data.
struct FileImportProvider: KilterCatalogProvider {
    let pickedURL: URL
    var displayName: String { "Imported file" }

    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // A Files-picked URL is security-scoped — open access for the copy, then release.
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilter-import-\(UUID().uuidString).sqlite3")
        if FileManager.default.fileExists(atPath: temp.path) {
            try FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.copyItem(at: pickedURL, to: temp)
        progress(1)
        return temp
    }
}

/// **Phase 2 — hosted-dataset download.** Fetches a board's catalog (gzipped SQLite) from a static host
/// the user controls (the Snappet Board Explorer Pages site by default), trims it on-device with the
/// chosen filters, and hands back a small importable file — so the user gets the catalog without the
/// `boardlib` + Files dance. It owns the module's **only** network egress (one GET to the configured
/// host), user-initiated, no analytics, nothing uploaded — see `KilterAuroraSync.swift` and
/// `pdd/context/decisions.md` for the (narrow, personal-use) legal posture.
struct HostedCatalogProvider: KilterCatalogProvider {
    let board: CatalogBoardEntry
    var filter: CatalogFilter
    var baseURL: String = kilterDefaultCatalogHost

    var displayName: String { "\(board.label) download" }

    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await HostedCatalogClient(baseURL: baseURL).buildCatalog(board: board, filter: filter,
                                                                     progress: progress)
    }
}

/// Orchestrates fetch → validate → install for any provider, exposing a small `phase` the sync UI and
/// Settings both observe. One place owns the "bring a catalog onto the device" flow so the empty-state
/// screen and the Settings "Refresh" row can't drift.
@MainActor
@Observable
final class KilterCatalogInstaller {
    enum Phase: Equatable {
        case idle
        case working(Double)
        case failed(String)
        case installed
    }

    private(set) var phase: Phase = .idle
    private let store = KilterCatalogStore.shared

    var isInstalled: Bool { store.isInstalled }
    var metadata: KilterCatalogMeta? { store.metadata() }

    /// Run a provider end-to-end. On success, posts the store's change notification so open screens
    /// reload. A failure anywhere (fetch / validate / install) surfaces a user-facing message and
    /// leaves any previously-installed catalog untouched.
    func install(using provider: KilterCatalogProvider) async {
        phase = .working(0)
        var produced: URL?
        do {
            let url = try await provider.fetch { fraction in
                Task { @MainActor in
                    if case .working = self.phase { self.phase = .working(fraction) }
                }
            }
            produced = url
            let validated = try KilterCatalogValidator.validate(url)
            let meta = KilterCatalogMeta(version: validated.version,
                                         climbCount: validated.climbCount,
                                         sizeBytes: validated.sizeBytes,
                                         source: provider.displayName,
                                         installedAt: .now)
            try store.install(from: url, meta: meta)   // consumes `url` on success
            phase = .installed
            store.postDidChange()
        } catch {
            if let produced, FileManager.default.fileExists(atPath: produced.path) {
                try? FileManager.default.removeItem(at: produced)
            }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Handle a Files-importer result by routing the picked URL through `FileImportProvider`.
    func importPicked(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            await install(using: FileImportProvider(pickedURL: url))
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
    }

    /// "Remove downloaded catalog" — delete the installed catalog and return to the opt-in state.
    func remove() {
        do {
            try store.clear()
            phase = .idle
            store.postDidChange()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
