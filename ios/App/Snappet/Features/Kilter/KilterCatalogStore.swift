import Foundation

/// Metadata sidecar describing one installed catalog, written next to its DB as `catalog.meta.json`.
/// Lets Settings show "vX • N climbs • M MB" without reopening SQLite.
struct KilterCatalogMeta: Codable, Sendable, Equatable {
    var version: String
    var climbCount: Int
    var sizeBytes: Int64
    /// Where it came from (e.g. "Imported file" / "Kilter download") — surfaced in Settings.
    var source: String
    var installedAt: Date
    /// Human-readable name for the library list (e.g. "Kilter · Original, Homewall · top 2000"). Optional
    /// so older single-catalog sidecars still decode.
    var name: String? = nil
}

/// One installed catalog in the on-device **library**.
struct InstalledCatalog: Identifiable, Sendable, Equatable {
    let id: String          // the catalog's directory name (a UUID)
    let meta: KilterCatalogMeta
    let url: URL            // the `.sqlite3` path
    var displayName: String { meta.name ?? meta.source }
}

/// Owns the on-device, **user-installed** Kilter catalog **library** under Application Support
/// (`…/Kilter/catalogs/<id>/catalog.sqlite3` + `catalog.meta.json`), plus which one is **active** (the
/// one the read-only `KilterCatalog` opens), tracked in `…/Kilter/active-catalog`.
///
/// The app ships **no** catalog (issue #42 — we don't redistribute Aurora Climbing's data). The user
/// installs one or more themselves (file import or the hosted download), and can keep several, switch
/// the active one, and remove any individually. A value type with a canonical `shared`; the
/// main-thread-only convention that `KilterCatalog` uses still holds for the *reader*, not this store.
struct KilterCatalogStore: Sendable {
    static let shared = KilterCatalogStore()

    /// Posted (on the main thread) after install / remove / activate so any open Kilter screen can
    /// reload the reader and re-evaluate availability.
    static let didChangeNotification = Notification.Name("snappet.kilterCatalogDidChange")

    private let root: URL
    private let catalogsDir: URL
    private let activeFile: URL
    /// Pre-multi-catalog single-file location, migrated into the library on first use.
    private let legacyDBURL: URL
    private let legacyMetaURL: URL

    /// `directory` is injectable for tests; production resolves Application Support.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kilter", isDirectory: true)
        self.root = base
        self.catalogsDir = base.appendingPathComponent("catalogs", isDirectory: true)
        self.activeFile = base.appendingPathComponent("active-catalog")
        self.legacyDBURL = base.appendingPathComponent("kilter.sqlite3")
        self.legacyMetaURL = base.appendingPathComponent("catalog.meta.json")
        migrateLegacyIfNeeded()
    }

    // MARK: - Active catalog (what the reader opens)

    private func activeId() -> String? {
        guard let id = try? String(contentsOf: activeFile, encoding: .utf8) else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func dbURL(for id: String) -> URL {
        catalogsDir.appendingPathComponent(id, isDirectory: true).appendingPathComponent("catalog.sqlite3")
    }

    private func metaURL(for id: String) -> URL {
        catalogsDir.appendingPathComponent(id, isDirectory: true).appendingPathComponent("catalog.meta.json")
    }

    /// The active catalog's `.sqlite3` path the reader opens (a non-existent path when nothing's active,
    /// so `KilterCatalog`'s `isInstalled`/open guards degrade cleanly).
    var resolvedCatalogURL: URL {
        if let id = activeId() { return dbURL(for: id) }
        return catalogsDir.appendingPathComponent("none/catalog.sqlite3")
    }

    var isInstalled: Bool {
        guard let id = activeId() else { return false }
        return FileManager.default.fileExists(atPath: dbURL(for: id).path)
    }

    /// Metadata for the active catalog (Settings' status rows; the reader doesn't need it).
    func metadata() -> KilterCatalogMeta? {
        guard let id = activeId() else { return nil }
        return readMeta(id)
    }

    var activeCatalogId: String? { isInstalled ? activeId() : nil }

    // MARK: - Library

    /// Every installed catalog, most-recently-installed first.
    func installed() -> [InstalledCatalog] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: catalogsDir.path) else { return [] }
        return ids.compactMap { id -> InstalledCatalog? in
            let db = dbURL(for: id)
            guard fm.fileExists(atPath: db.path), let meta = readMeta(id) else { return nil }
            return InstalledCatalog(id: id, meta: meta, url: db)
        }
        .sorted { $0.meta.installedAt > $1.meta.installedAt }
    }

    /// Move a validated catalog into a **new** library entry (it does not replace existing ones) and make
    /// it active. `tempURL` must already live on this device (a provider produced it); it is consumed.
    /// Returns the new catalog's id.
    @discardableResult
    func install(from tempURL: URL, meta: KilterCatalogMeta) throws -> String {
        let fm = FileManager.default
        let id = UUID().uuidString
        let dir = catalogsDir.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dbURL(for: id)
        if fm.fileExists(atPath: db.path) { try fm.removeItem(at: db) }
        try fm.moveItem(at: tempURL, to: db)
        try writeMeta(meta, id: id)
        try setActive(id: id)
        return id
    }

    /// Remove one catalog. If it was active, the most-recent remaining catalog becomes active (or none).
    func remove(id: String) throws {
        let dir = catalogsDir.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        if activeId() == id {
            if let next = installed().first { try setActive(id: next.id) } else { clearActive() }
        }
    }

    /// Make `id` the catalog the reader opens.
    func setActive(id: String) throws {
        guard FileManager.default.fileExists(atPath: dbURL(for: id).path) else { return }
        try Data(id.utf8).write(to: activeFile, options: .atomic)
    }

    /// Remove the **entire** library (used by tests + the UI-test fixture reset).
    func clear() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: catalogsDir.path) { try fm.removeItem(at: catalogsDir) }
        clearActive()
        if fm.fileExists(atPath: legacyDBURL.path) { try? fm.removeItem(at: legacyDBURL) }
        if fm.fileExists(atPath: legacyMetaURL.path) { try? fm.removeItem(at: legacyMetaURL) }
    }

    // MARK: - Change notification

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

    // MARK: - internals

    private func clearActive() {
        try? FileManager.default.removeItem(at: activeFile)
    }

    private func readMeta(_ id: String) -> KilterCatalogMeta? {
        guard let data = try? Data(contentsOf: metaURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KilterCatalogMeta.self, from: data)
    }

    private func writeMeta(_ meta: KilterCatalogMeta, id: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: metaURL(for: id), options: .atomic)
    }

    /// One-time: fold a pre-multi-catalog single install (`…/Kilter/kilter.sqlite3`) into the library so
    /// an already-installed catalog survives the upgrade.
    private func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDBURL.path) else { return }
        let id = UUID().uuidString
        let dir = catalogsDir.appendingPathComponent(id, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: legacyDBURL, to: dbURL(for: id))
            if let data = try? Data(contentsOf: legacyMetaURL) {
                try? data.write(to: metaURL(for: id), options: .atomic)
                try? fm.removeItem(at: legacyMetaURL)
            } else {
                let attrs = try? fm.attributesOfItem(atPath: dbURL(for: id).path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let meta = KilterCatalogMeta(version: "migrated", climbCount: 0, sizeBytes: size,
                                             source: "Imported file", installedAt: Date(), name: "Imported catalog")
                try? writeMeta(meta, id: id)
            }
            try? setActive(id: id)
        } catch {
            // If migration fails, leave the legacy file alone rather than lose it.
        }
    }
}
