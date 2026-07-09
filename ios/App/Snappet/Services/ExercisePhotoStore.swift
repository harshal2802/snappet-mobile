import Foundation
import UIKit

/// Default host for the exercise guide-photo pack — the Board Explorer Pages site's
/// `exercise-photos/` directory (same host as `kilterDefaultCatalogHost` / `kilterGeneratorHost`).
/// Overridable via the `workout.photos.host` default so a local `python -m http.server` can serve
/// a test pack to the simulator. Built + published with `tools/workout/build_photo_pack.py`.
let workoutPhotoPackHost = "https://harshal2802.github.io/Snappet/exercise-photos/"

enum ExercisePhotoStoreError: LocalizedError {
    case http(Int)
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Couldn't reach the photo host (HTTP \(code)). Check your connection."
        case .emptyDownload: return "The photo download was empty. Try again."
        }
    }
}

/// Downloads + serves the **exercise guide-photo pack** (start/end photos for the bundled
/// catalog; public-domain Free Exercise DB data re-hosted on the user's Pages site). Mirrors
/// `KilterGeneratorAssets`: strictly user-initiated download into Application Support, streamed
/// with progress, idempotent, removable from Settings, fully offline afterward. The pack stays a
/// single file on disk — photos are sliced out with range reads through the pure
/// `ExercisePhotoPack` index, with a bounded `NSCache` for decoded images.
final class ExercisePhotoStore: @unchecked Sendable {
    static let shared = ExercisePhotoStore()

    /// The `@AppStorage` key Settings uses to override the host (testing against a local server).
    static let hostDefaultsKey = "workout.photos.host"

    private let session: URLSession
    private let dir: URL
    private let lock = NSLock()
    private var cachedIndex: ExercisePhotoPack.Index?
    private let images = NSCache<NSString, UIImage>()

    init(directoryName: String = "ExerciseGuidePhotos") {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.dir = support.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        // Cost-bounded like AssetPosterLoader (prompt 106): a count limit doesn't bound memory
        // for decoded bitmaps. ~24 MB ≈ dozens of ≤640px guides.
        images.totalCostLimit = 24 * 1024 * 1024
    }

    private static func bitmapCost(_ img: UIImage) -> Int {
        Int(img.size.width * img.scale) * Int(img.size.height * img.scale) * 4
    }

    var packURL: URL { dir.appendingPathComponent("photos.spack") }
    /// The host manifest as stamped at install time (drives the Settings status row).
    var stampURL: URL { dir.appendingPathComponent("installed-manifest.json") }

    private var baseURL: String {
        let host = UserDefaults.standard.string(forKey: Self.hostDefaultsKey) ?? workoutPhotoPackHost
        return host.hasSuffix("/") ? host : host + "/"
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: packURL.path) }

    var installedManifest: PhotoPackManifest? {
        guard let data = try? Data(contentsOf: stampURL) else { return nil }
        return try? JSONDecoder().decode(PhotoPackManifest.self, from: data)
    }

    // MARK: - Reading photos

    /// How many guide photos the installed pack has for an exercise (0 when not installed —
    /// custom exercises and upstream gaps simply have no index entry).
    func photoCount(exerciseId: String) -> Int {
        index()?.photoRanges(for: exerciseId).count ?? 0
    }

    /// Decode one guide photo (slot 0 = start position, 1 = end) via a range read of the pack.
    func photo(exerciseId: String, slot: Int) -> UIImage? {
        let key = "\(exerciseId)#\(slot)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let ranges = index()?.photoRanges(for: exerciseId), ranges.indices.contains(slot),
              let handle = try? FileHandle(forReadingFrom: packURL) else { return nil }
        defer { try? handle.close() }
        let range = ranges[slot]
        guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil,
              let data = try? Self.readFully(handle, count: Int(range.upperBound - range.lowerBound)),
              let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: key, cost: Self.bitmapCost(image))
        return image
    }

    /// Pre-parse the index off the caller's critical path (no-op when already cached / no pack).
    func warmIndex() { _ = index() }

    /// Parse (once) and cache the pack index; nil when no pack is installed or it's unreadable.
    private func index() -> ExercisePhotoPack.Index? {
        lock.lock(); defer { lock.unlock() }
        if let cachedIndex { return cachedIndex }
        cachedIndex = try? Self.readIndex(packURL: packURL)
        return cachedIndex
    }

    private static func readIndex(packURL: URL) throws -> ExercisePhotoPack.Index {
        let handle = try FileHandle(forReadingFrom: packURL)
        defer { try? handle.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: packURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let header = try readFully(handle, count: ExercisePhotoPack.headerLength)
        let indexLength = try ExercisePhotoPack.indexLength(header: header)
        let json = try readFully(handle, count: indexLength)
        guard json.count == indexLength else { throw ExercisePhotoPack.PackError.truncated }
        return try ExercisePhotoPack.parseIndex(json, packSize: size)
    }

    /// `FileHandle.read(upToCount:)` may legally return fewer bytes than asked — loop until the
    /// requested count (or EOF, which callers treat as truncation).
    private static func readFully(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }

    // MARK: - Install / remove

    /// Fetch the host manifest (one GET) — used to show the real size before the user commits.
    func fetchManifest() async throws -> PhotoPackManifest {
        guard let url = URL(string: baseURL + "manifest.json") else {
            throw ExercisePhotoStoreError.http(0)
        }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExercisePhotoStoreError.http(http.statusCode)
        }
        return try JSONDecoder().decode(PhotoPackManifest.self, from: data)
    }

    /// Download + validate + install the pack (idempotent to re-run: replaces the old pack).
    /// `progress` runs 0→1 over the pack download. Strictly user-initiated — nothing here is
    /// called outside an explicit tap.
    func install(progress: @escaping @Sendable (Double) -> Void) async throws -> PhotoPackManifest {
        let manifest = try await fetchManifest()
        let tmp = packURL.appendingPathExtension("part")
        try await download(manifest.file, to: tmp, expectedBytes: manifest.sizeBytes, progress: progress)

        // Validate before adopting: a bad magic / truncated index never replaces a good pack.
        _ = try Self.readIndex(packURL: tmp)

        try? FileManager.default.removeItem(at: packURL)
        try FileManager.default.moveItem(at: tmp, to: packURL)
        do {
            let stamp = try JSONEncoder().encode(manifest)
            try stamp.write(to: stampURL)
        } catch {
            // Never leave a pack without its stamp — the two are the single "installed" truth.
            try? FileManager.default.removeItem(at: packURL)
            invalidateCaches()
            throw error
        }
        invalidateCaches()
        _ = index()   // warm the new index here (off-main) so no view body pays the first parse
        return manifest
    }

    /// Delete the pack (Settings → reclaim space). The app falls back to symbols-only, as before.
    func remove() {
        try? FileManager.default.removeItem(at: packURL)
        try? FileManager.default.removeItem(at: stampURL)
        invalidateCaches()
    }

    private func invalidateCaches() {
        lock.lock(); cachedIndex = nil; lock.unlock()
        images.removeAllObjects()
    }

    /// Stream a file to `dest` with progress — same shape as `KilterGeneratorAssets.download`.
    private func download(_ filename: String, to dest: URL, expectedBytes: Int64,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = URL(string: baseURL + filename) else { throw ExercisePhotoStoreError.http(0) }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw ExercisePhotoStoreError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw ExercisePhotoStoreError.http(http.statusCode)
        }

        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        let total = http.expectedContentLength > 0 ? http.expectedContentLength : expectedBytes
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                // `write(contentsOf:)`, not the legacy `write(_:)` — the legacy call raises an ObjC
                // NSFileHandleOperationException on a write failure (disk full mid-download) that Swift
                // cannot catch; the throwing variant surfaces it as a normal error to the caller.
                try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(min(1, Double(received) / Double(total))) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        guard received > 0 else { throw ExercisePhotoStoreError.emptyDownload }
        progress(1)
    }
}

/// The one observable install/remove state both the detail-view CTA and the Workout Settings
/// section render, so the two surfaces can't drift (same `Phase` shape as
/// `KilterCatalogInstaller`). A singleton because a download started from an exercise detail
/// must stay visible in Settings and vice versa.
@MainActor
@Observable
final class ExercisePhotoInstaller {
    static let shared = ExercisePhotoInstaller()

    enum Phase: Equatable {
        case idle
        case working(Double)
        case failed(String)
        case installed
    }

    private(set) var phase: Phase = .idle
    private(set) var installedManifest: PhotoPackManifest?
    private let store: ExercisePhotoStore

    init(store: ExercisePhotoStore = .shared) {
        self.store = store
        installedManifest = store.isInstalled ? store.installedManifest : nil
        if installedManifest != nil {
            phase = .installed
            // Warm the pack index off-main so the first view body pays a dict lookup, not a parse.
            Task.detached(priority: .utility) { [store] in store.warmIndex() }
        }
    }

    var isInstalled: Bool { installedManifest != nil }

    func install() async {
        if case .working = phase { return }   // a download is already running
        phase = .working(0)
        do {
            let manifest = try await store.install { fraction in
                Task { @MainActor in
                    if case .working = self.phase { self.phase = .working(fraction) }
                }
            }
            installedManifest = manifest
            phase = .installed
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func remove() {
        store.remove()
        installedManifest = nil
        phase = .idle
    }
}
