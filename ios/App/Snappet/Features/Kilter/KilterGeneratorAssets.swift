import Foundation

/// Default host for the generator assets — the board-explorer's `climb-generator/` directory (same
/// GitHub Pages site the catalog downloads from). One GET each for the manifest, model, and meta; nothing
/// is uploaded. See `kilterDefaultCatalogHost` for the catalog equivalent + the legal posture (#42).
let kilterGeneratorHost = "https://harshal2802.github.io/Snappet/climb-generator/"

/// The host's `manifest.json` — the available generator models. The app installs the `default` one.
struct KilterGeneratorManifest: Codable, Sendable {
    let `default`: String
    let models: [Entry]

    struct Entry: Codable, Sendable, Identifiable {
        let id: String
        let label: String
        let model: String     // filename of the .onnx
        let meta: String      // filename of the meta.json
        let sizeBytes: Int64?
        let description: String?
    }
}

enum KilterGeneratorAssetError: LocalizedError {
    case http(Int)
    case emptyManifest
    case emptyDownload

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Couldn't reach the generator host (HTTP \(code)). Check your connection."
        case .emptyManifest: return "The generator manifest had no models."
        case .emptyDownload: return "The model download was empty. Try again."
        }
    }
}

/// Lazy-downloads + caches the on-device generator's model + meta (the ~9 MB `model.q.onnx` and
/// `meta.json`) into Application Support, so the app binary stays slim and the model can be updated host-
/// side without an app release. Mirrors the catalog's `HostedCatalogClient` download posture (streamed
/// GETs with progress, ephemeral session). `ensureInstalled` is idempotent — once cached it returns the
/// decoded `KilterGeneratorModel` without touching the network. Foundation only (no ONNX).
final class KilterGeneratorAssets: Sendable {
    static let shared = KilterGeneratorAssets()

    private let baseURL: String
    private let session: URLSession
    private let dir: URL
    /// Records which model id is cached, so a manifest default-change re-downloads.
    private let stampURL: URL

    init(baseURL: String = kilterGeneratorHost) {
        self.baseURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.dir = support.appendingPathComponent("KilterGenerator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stampURL = dir.appendingPathComponent("installed.json")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    var modelURL: URL { dir.appendingPathComponent("model.onnx") }
    var metaURL: URL { dir.appendingPathComponent("meta.json") }

    /// True when both assets are already on disk (so the Generate tab can skip the download UI).
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
            && FileManager.default.fileExists(atPath: metaURL.path)
    }

    /// Ensure the model + meta are cached, downloading them on first use, and return the decoded model.
    /// Idempotent; `progress` runs 0→1 over the (meta + model) download (skipped when already installed).
    func ensureInstalled(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> KilterGeneratorModel {
        if isInstalled, let model = try? KilterGeneratorModel.load(metaURL: metaURL) {
            progress(1)
            return model
        }
        let manifest = try await fetchManifest()
        guard let entry = manifest.models.first(where: { $0.id == manifest.default })
                ?? manifest.models.first else {
            throw KilterGeneratorAssetError.emptyManifest
        }
        // Meta is tiny (~150 KB); model is ~9 MB — weight progress accordingly.
        try await download(entry.meta, to: metaURL) { progress($0 * 0.05) }
        try await download(entry.model, to: modelURL) { progress(0.05 + $0 * 0.95) }
        writeStamp(modelId: entry.id)
        progress(1)
        return try KilterGeneratorModel.load(metaURL: metaURL)
    }

    /// Delete the cached assets (e.g. from Settings, to reclaim space).
    func remove() {
        try? FileManager.default.removeItem(at: modelURL)
        try? FileManager.default.removeItem(at: metaURL)
        try? FileManager.default.removeItem(at: stampURL)
    }

    // MARK: - Networking

    private func fetchManifest() async throws -> KilterGeneratorManifest {
        guard let url = URL(string: baseURL + "manifest.json") else { throw KilterGeneratorAssetError.emptyManifest }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KilterGeneratorAssetError.http(http.statusCode)
        }
        return try JSONDecoder().decode(KilterGeneratorManifest.self, from: data)
    }

    /// Stream a file to `dest` with progress, mirroring `HostedCatalogClient.download`.
    private func download(_ filename: String, to dest: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = URL(string: baseURL + filename) ?? URL(fileURLWithPath: filename)
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw KilterGeneratorAssetError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw KilterGeneratorAssetError.http(http.statusCode) }

        let tmp = dest.appendingPathExtension("part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        let total = http.expectedContentLength
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                // Throwing write, not the legacy `write(_:)` — disk-full mid-download must surface as
                // a thrown error, not an uncatchable NSFileHandleOperationException.
                try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(min(1, Double(received) / Double(total))) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        try? handle.close()
        guard received > 0 else { throw KilterGeneratorAssetError.emptyDownload }
        // Atomic-ish swap so a half-written file is never treated as installed.
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        progress(1)
    }

    private func writeStamp(modelId: String) {
        let json = try? JSONSerialization.data(withJSONObject: ["modelId": modelId])
        try? json?.write(to: stampURL)
    }
}
