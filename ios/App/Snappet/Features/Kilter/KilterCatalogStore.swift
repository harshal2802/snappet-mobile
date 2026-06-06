import Foundation

/// Metadata sidecar describing the currently-installed catalog, written next to the DB as
/// `catalog.meta.json`. Lets Settings show "installed vX • N climbs • M MB" without reopening SQLite.
struct KilterCatalogMeta: Codable, Sendable, Equatable {
    var version: String
    var climbCount: Int
    var sizeBytes: Int64
    /// Where it came from (e.g. "Imported file") — surfaced in Settings, never a network identity.
    var source: String
    var installedAt: Date
}

/// Owns the on-device, **user-installed** Kilter catalog file and its meta sidecar under Application
/// Support (`…/Kilter/kilter.sqlite3` + `catalog.meta.json`).
///
/// The app ships **no** catalog (issue #42 — we don't redistribute Aurora Climbing's proprietary
/// data). The user installs one themselves via a `KilterCatalogProvider` (file import in Phase 1) and
/// the read-only `KilterCatalog` opens it from `resolvedCatalogURL`. When nothing is installed the
/// module shows the opt-in `KilterCatalogSyncView` instead of a browse list.
///
/// Pure file IO (resolves paths off `FileManager`), so it's safe to call from a background task — the
/// import runs `async`. A value type with a canonical `shared`; the main-thread-only convention that
/// `KilterCatalog` uses still holds for the *reader*, not this store.
struct KilterCatalogStore: Sendable {
    static let shared = KilterCatalogStore()

    /// Posted (on the main thread) after a successful `install` or `clear` so any open Kilter screen
    /// can reload the reader and re-evaluate availability.
    static let didChangeNotification = Notification.Name("snappet.kilterCatalogDidChange")

    private let directory: URL
    let resolvedCatalogURL: URL
    private let metaURL: URL

    /// `directory` is injectable for tests; production resolves Application Support.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kilter", isDirectory: true)
        self.directory = base
        self.resolvedCatalogURL = base.appendingPathComponent("kilter.sqlite3")
        self.metaURL = base.appendingPathComponent("catalog.meta.json")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: resolvedCatalogURL.path)
    }

    func metadata() -> KilterCatalogMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KilterCatalogMeta.self, from: data)
    }

    /// Move a validated catalog into place (replacing any existing one) and write the meta sidecar.
    /// `tempURL` must already live on this device (a provider produced it); it is consumed by the move.
    func install(from tempURL: URL, meta: KilterCatalogMeta) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: resolvedCatalogURL.path) { try fm.removeItem(at: resolvedCatalogURL) }
        try fm.moveItem(at: tempURL, to: resolvedCatalogURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    /// Remove the installed catalog + meta ("Remove downloaded catalog"), returning the module to its
    /// opt-in empty state.
    func clear() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: resolvedCatalogURL.path) { try fm.removeItem(at: resolvedCatalogURL) }
        if fm.fileExists(atPath: metaURL.path) { try fm.removeItem(at: metaURL) }
    }

    /// Notify open screens, always on the main thread (SwiftUI observers expect it).
    func postDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }
}
