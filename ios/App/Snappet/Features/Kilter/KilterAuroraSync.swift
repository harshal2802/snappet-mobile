import Foundation
import SQLite3

/// **Phase 2 — in-app catalog download from a hosted dataset.** Fetches a board's full catalog as a
/// gzipped SQLite from a static host (the Snappet **Board Explorer** GitHub Pages site by default), then
/// trims it on-device to a small, mobile-importable catalog using the same filters the explorer's
/// `exportDb.ts` uses. The built file is validated + installed by the usual `KilterCatalogInstaller`
/// path, so the reader never learns where the bytes came from.
///
/// ⚠️ Legal posture (issue #42): the dataset is **user-hosted** (the user published it under their own
/// acceptance of Aurora's Terms of Use) and the app simply downloads a file from a URL the user controls
/// — much closer to "bring your own file" than scraping Aurora. The app does **no** Aurora API calls, no
/// analytics, nothing is uploaded; egress is one GET to the configured host. Personal/sideload posture
/// unchanged. (An earlier draft hit Aurora's `/sync` directly; that host rejects all TLS handshakes, so
/// this hosted-dataset path replaced it.)

/// Default host for the gzipped board datasets + `manifest.json` (the Board Explorer's `board-data/`).
let kilterDefaultCatalogHost = "https://harshal2802.github.io/Snappet/board-data/"

/// One board in the host's `manifest.json`. Only `importableToMobile` boards are offered (the reader is
/// Kilter-shaped — layouts 1 & 8).
struct CatalogBoardEntry: Codable, Sendable, Identifiable, Equatable {
    let board: String
    let label: String
    let file: String
    var url: String?
    let climbs: Int
    let importableToMobile: Bool
    let sizeBytesGz: Int64?

    var id: String { board }
}

struct CatalogManifest: Codable, Sendable {
    let boards: [CatalogBoardEntry]
}

/// The subset filter applied on-device after download. Mirrors the Board Explorer's `FilterState`
/// (`query.ts buildConditions`) plus a `maxClimbs` top-N cap (the explorer expects the user to narrow
/// the set; on a phone we always cap, like `build_bundled_db.py --limit`). Defaults are the explorer's
/// "mobile-compatible" mode: listed + single-frame + Kilter layouts.
struct CatalogFilter: Sendable, Equatable {
    var layoutIds: [Int] = [1, 8]      // empty = all layouts
    var angle: Int?                    // specific board angle, nil = any
    var gradeMin: Int?
    var gradeMax: Int?
    var minAscents: Int?
    var minQuality: Double?
    var setter: String = ""
    var name: String = ""
    var benchmarkOnly = false
    var listedOnly = true
    var singleFrameOnly = true
    /// Top-N most-climbed matching problems to keep (bounds the installed file size). 0 = no cap.
    var maxClimbs = 2000
}

enum HostedCatalogError: LocalizedError {
    case http(Int)
    case notImportable(String)
    case emptyDownload
    case badGzip
    case noCatalogData
    case cantCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Couldn't reach the catalog host (HTTP \(code)). Check your connection and the host URL."
        case .notImportable(let b): return "“\(b)” isn't importable into this app yet — pick Kilter."
        case .emptyDownload: return "The download was empty. Try again."
        case .badGzip: return "The downloaded file wasn't valid gzip — check the host URL."
        case .noCatalogData: return "No climbs matched those filters. Widen the grade range or raise the climb cap."
        case .cantCreateFile(let m): return "Couldn't build the catalog on this device (\(m))."
        }
    }
}

/// Downloads + trims a hosted board dataset into a mobile-importable catalog `.sqlite3`.
final class HostedCatalogClient {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Reference/geometry tables copied WHOLE (mirrors Board Explorer `schema.ts` FULL_TABLES).
    private static let fullTables = [
        "difficulty_grades", "products", "product_sizes", "layouts", "sets",
        "product_sizes_layouts_sets", "products_angles", "placement_roles", "holes", "holds",
        "placements", "leds",
    ]
    /// Climb tables, subset by the filtered uuids → their climb-key column.
    private static let climbTables: [(table: String, key: String)] = [
        ("climbs", "uuid"), ("climb_stats", "climb_uuid"),
        ("climb_cache_fields", "climb_uuid"), ("beta_links", "climb_uuid"),
    ]

    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = kilterDefaultCatalogHost) {
        self.baseURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    private func absolute(_ path: String) -> URL {
        if let u = URL(string: path), u.scheme != nil { return u }   // manifest entry may carry an absolute url
        return URL(string: baseURL + path)!
    }

    /// The boards offered in the picker (importable ones), from the host manifest. Falls back to a lone
    /// Kilter entry if the manifest can't be read, so the feature still works offline-of-manifest.
    func importableBoards() async -> [CatalogBoardEntry] {
        let fallback = [CatalogBoardEntry(board: "kilter", label: "Kilter Board",
                                          file: "kilter.sqlite.gz", url: nil, climbs: 0,
                                          importableToMobile: true, sizeBytesGz: nil)]
        guard let url = URL(string: baseURL + "manifest.json"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let manifest = try? JSONDecoder().decode(CatalogManifest.self, from: data)
        else { return fallback }
        let importable = manifest.boards.filter { $0.importableToMobile }
        return importable.isEmpty ? fallback : importable
    }

    /// Download → gunzip → filter → return a small catalog file for the installer.
    func buildCatalog(board: CatalogBoardEntry, filter: CatalogFilter,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard board.importableToMobile else { throw HostedCatalogError.notImportable(board.label) }

        let tmp = FileManager.default.temporaryDirectory
        let gzURL = tmp.appendingPathComponent("kilter-dl-\(UUID().uuidString).sqlite.gz")
        let rawURL = tmp.appendingPathComponent("kilter-raw-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: gzURL); try? FileManager.default.removeItem(at: rawURL) }

        try await download(board.url ?? board.file, to: gzURL) { f in progress(f * 0.75) }
        progress(0.76)
        try gunzip(gzURL, to: rawURL)
        progress(0.85)

        let outURL = tmp.appendingPathComponent("kilter-catalog-\(UUID().uuidString).sqlite3")
        try buildFilteredCatalog(sourcePath: rawURL.path, filter: filter, outPath: outURL.path)
        progress(1)
        return outURL
    }

    // MARK: - Download (with progress)

    private func download(_ path: String, to dest: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await session.bytes(from: absolute(path))
        guard let http = response as? HTTPURLResponse else { throw HostedCatalogError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw HostedCatalogError.http(http.statusCode) }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        let total = http.expectedContentLength
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                handle.write(buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(min(1, Double(received) / Double(total))) }
            }
        }
        if !buffer.isEmpty { handle.write(buffer); received += Int64(buffer.count) }
        guard received > 0 else { throw HostedCatalogError.emptyDownload }
        progress(1)
    }

    // MARK: - gunzip (streaming zlib inflate)

    func gunzip(_ src: URL, to dst: URL) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }

        var stream = z_stream()
        // windowBits 47 (= 32 + 15) → auto-detect gzip/zlib with the max window.
        guard inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HostedCatalogError.badGzip
        }
        defer { inflateEnd(&stream) }

        let outSize = 1 << 18
        var outBuffer = [UInt8](repeating: 0, count: outSize)
        var finished = false

        while !finished {
            let chunk = input.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }   // ran out of input before Z_STREAM_END → truncated
            var threw: Error?
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(chunk.count)
                while stream.avail_in > 0 && !finished {
                    let produced: Int? = outBuffer.withUnsafeMutableBufferPointer { out -> Int? in
                        stream.next_out = out.baseAddress
                        stream.avail_out = uInt(outSize)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR { return nil }
                        if status == Z_STREAM_END { finished = true }
                        return outSize - Int(stream.avail_out)
                    }
                    guard let produced else { threw = HostedCatalogError.badGzip; return }
                    if produced > 0 { output.write(Data(outBuffer[0..<produced])) }
                    if produced == 0 && !finished { break }   // need more input
                }
            }
            if let threw { throw threw }
        }
        guard finished else { throw HostedCatalogError.badGzip }
    }

    // MARK: - Filtered catalog build (mirrors Board Explorer exportDb.ts)

    func buildFilteredCatalog(sourcePath: String, filter: CatalogFilter, outPath: String) throws {
        if FileManager.default.fileExists(atPath: outPath) { try FileManager.default.removeItem(atPath: outPath) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(outPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db); throw HostedCatalogError.cantCreateFile("open output")
        }
        defer { sqlite3_close(db) }

        try exec(db, "ATTACH DATABASE ? AS src", bind: [sourcePath])
        defer { try? exec(db, "DETACH DATABASE src") }
        try exec(db, "PRAGMA journal_mode = OFF")
        try exec(db, "PRAGMA synchronous = OFF")

        let fullPresent = Self.fullTables.filter { tableExists(db, "src", $0) }
        let climbPresent = Self.climbTables.filter { tableExists(db, "src", $0.table) }

        // 1. Recreate every table's schema from the source DDL (verbatim CREATE TABLE).
        for t in fullPresent + climbPresent.map(\.table) {
            guard let ddl = scalarText(db, "SELECT sql FROM src.sqlite_master WHERE type='table' AND name=?", bind: [t])
            else { continue }
            try exec(db, ddl)
        }

        // 2. Copy reference/geometry tables whole.
        try exec(db, "BEGIN")
        for t in fullPresent { try exec(db, "INSERT INTO \"\(t)\" SELECT * FROM src.\"\(t)\"") }
        try exec(db, "COMMIT")

        // 3. Resolve the filtered, capped uuid set into a temp table.
        try exec(db, "CREATE TEMP TABLE _keep (uuid TEXT PRIMARY KEY)")
        let (where_, params) = conditions(filter)
        var uuidSQL = """
            INSERT OR IGNORE INTO _keep(uuid)
            SELECT c.uuid FROM src.climbs c JOIN src.climb_stats cs ON cs.climb_uuid = c.uuid
            WHERE \(where_) GROUP BY c.uuid ORDER BY MAX(cs.ascensionist_count) DESC
            """
        if filter.maxClimbs > 0 { uuidSQL += " LIMIT \(filter.maxClimbs)" }
        try exec(db, uuidSQL, bind: params)

        guard scalarInt(db, "SELECT COUNT(*) FROM _keep") > 0 else { throw HostedCatalogError.noCatalogData }

        // 4. Subset the climb tables against _keep.
        try exec(db, "BEGIN")
        for (t, key) in climbPresent {
            try exec(db, "INSERT INTO \"\(t)\" SELECT \"\(t)\".* FROM src.\"\(t)\" AS \"\(t)\" "
                + "JOIN _keep k ON k.uuid = \"\(t)\".\"\(key)\"")
        }
        try exec(db, "COMMIT")

        // 5. Recreate indexes for the copied tables (best-effort — skip any that won't apply).
        let kept = Set(fullPresent + climbPresent.map(\.table))
        forEachRow(db, "SELECT sql, tbl_name FROM src.sqlite_master WHERE type='index' AND sql IS NOT NULL") { stmt in
            let sql = Self.text(stmt, 0), tbl = Self.text(stmt, 1)
            if kept.contains(tbl), !sql.isEmpty { try? self.exec(db, sql) }
        }

        try exec(db, "DROP TABLE _keep")
        try exec(db, "DETACH DATABASE src")
        try exec(db, "VACUUM")
    }

    /// WHERE clause + bound params mirroring Board Explorer `query.ts buildConditions`.
    private func conditions(_ f: CatalogFilter) -> (String, [Any]) {
        var conds: [String] = []
        var params: [Any] = []
        if f.listedOnly { conds.append("c.is_listed = 1") }
        if f.singleFrameOnly { conds.append("c.frames_count = 1") }
        if !f.layoutIds.isEmpty {
            conds.append("c.layout_id IN (\(f.layoutIds.map { String($0) }.joined(separator: ",")))")
        }
        if let angle = f.angle { conds.append("cs.angle = ?"); params.append(angle) }
        if let lo = f.gradeMin { conds.append("ROUND(cs.display_difficulty) >= ?"); params.append(lo) }
        if let hi = f.gradeMax { conds.append("ROUND(cs.display_difficulty) <= ?"); params.append(hi) }
        if let a = f.minAscents { conds.append("cs.ascensionist_count >= ?"); params.append(a) }
        if let q = f.minQuality { conds.append("cs.quality_average >= ?"); params.append(q) }
        let setter = f.setter.trimmingCharacters(in: .whitespaces)
        if !setter.isEmpty { conds.append("c.setter_username LIKE ?"); params.append("%\(setter)%") }
        let name = f.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { conds.append("c.name LIKE ?"); params.append("%\(name)%") }
        if f.benchmarkOnly { conds.append("cs.benchmark_difficulty IS NOT NULL") }
        return (conds.isEmpty ? "1=1" : conds.joined(separator: " AND "), params)
    }

    // MARK: - tiny sqlite helpers

    private func tableExists(_ db: OpaquePointer?, _ schema: String, _ table: String) -> Bool {
        scalarInt(db, "SELECT COUNT(*) FROM \(schema).sqlite_master WHERE type='table' AND name=?", bind: [table]) > 0
    }

    private func exec(_ db: OpaquePointer?, _ sql: String, bind params: [Any] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw sqliteError(db) }
    }

    private func bindAll(_ stmt: OpaquePointer?, _ params: [Any]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String, bind params: [Any] = []) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, params)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func scalarText(_ db: OpaquePointer?, _ sql: String, bind params: [Any] = []) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, params)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func forEachRow(_ db: OpaquePointer?, _ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func sqliteError(_ db: OpaquePointer?) -> Error {
        HostedCatalogError.cantCreateFile(String(cString: sqlite3_errmsg(db)))
    }
}
