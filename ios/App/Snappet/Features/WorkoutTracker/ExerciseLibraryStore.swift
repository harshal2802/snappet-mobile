import Foundation

/// Metadata sidecar for the installed exercise library, stored next to `catalog.json`.
struct ExerciseLibraryMeta: Codable, Sendable, Equatable {
    var exerciseCount: Int
    var sizeBytes: Int64
    var source: String
    var installedAt: Date
    /// The base URL the catalog was downloaded from (surfaced in Settings).
    var sourceURL: String? = nil
}

/// Manages the opt-in, user-downloaded exercise library on disk.
///
/// The bundled catalog (873 exercises, always offline) lives in `ExerciseCatalog`.
/// This store owns the *extra* 1,324 exercises from the Snappet-hosted dataset
/// (`harshal2802/Snappet → exercises-dataset/data/exercises.json`), downloaded once
/// at the user's explicit request and cached at:
///   `Application Support/ExerciseLibrary/catalog.json`
///   `Application Support/ExerciseLibrary/catalog.meta.json`
///
/// Analogous to `KilterCatalogStore` but simpler — the catalog is JSON, not SQLite.
struct ExerciseLibraryStore: Sendable {
    static let shared = ExerciseLibraryStore()

    /// Posted on the main thread after install or removal so open screens re-merge the catalog.
    static let didChangeNotification = Notification.Name("snappet.exerciseLibraryDidChange")

    private let root: URL
    private let catalogURL: URL
    private let metaURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExerciseLibrary", isDirectory: true)
        root = base
        catalogURL = base.appendingPathComponent("catalog.json")
        metaURL = base.appendingPathComponent("catalog.meta.json")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: catalogURL.path)
    }

    func metadata() -> ExerciseLibraryMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ExerciseLibraryMeta.self, from: data)
    }

    /// Decode and return all downloaded exercises. Returns `[]` when nothing is installed.
    /// Called at @MainActor scope; reading a local JSON file is fast enough for sync use.
    func load() -> [Exercise] {
        guard isInstalled,
              let data = try? Data(contentsOf: catalogURL),
              let exercises = try? JSONDecoder().decode([Exercise].self, from: data)
        else { return [] }
        return exercises
    }

    /// Move a validated catalog temp file into place and write metadata. Overwrites any
    /// previous installation. `tempURL` must live on this device (already fetched).
    func install(from tempURL: URL, meta: ExerciseLibraryMeta) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: catalogURL.path) {
            try fm.removeItem(at: catalogURL)
        }
        try fm.moveItem(at: tempURL, to: catalogURL)
        try writeMeta(meta)
    }

    /// Remove the installed catalog and its sidecar.
    func clear() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: catalogURL.path) { try fm.removeItem(at: catalogURL) }
        if fm.fileExists(atPath: metaURL.path)    { try fm.removeItem(at: metaURL) }
    }

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

    private func writeMeta(_ meta: ExerciseLibraryMeta) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: metaURL, options: .atomic)
    }
}
