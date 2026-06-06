import Foundation
import SQLite3

/// Validates a candidate `.sqlite3` before it's installed as the Kilter catalog: it must be a readable
/// SQLite database that carries the tables the read layer needs and has at least one listed climb.
/// This is what makes file import safe — a user can pick any file and a malformed/foreign one is
/// rejected with a clear message instead of crashing the reader or installing junk.
///
/// Pure + device-free (just SQLite + Foundation), so it unit-tests without a simulator.
enum KilterCatalogValidator {
    /// What a valid catalog yields: a derived version string + counts for the meta sidecar.
    struct Validated: Sendable, Equatable {
        let version: String
        let climbCount: Int
        let sizeBytes: Int64
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case missingTables([String])
        case noClimbs
        case tooLarge(Int64)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file isn't a readable SQLite database."
            case .missingTables(let tables):
                return "That database is missing required Kilter tables "
                    + "(\(tables.joined(separator: ", "))) — it doesn't look like a Kilter catalog."
            case .noClimbs:
                return "That catalog has no climbs in it."
            case .tooLarge(let bytes):
                return "That file is too large (\(bytes / 1_000_000) MB) to be a Kilter catalog."
            }
        }
    }

    /// The minimum tables the reader needs to browse + render + illuminate (matches issue #42).
    static let requiredTables = ["difficulty_grades", "layouts", "climbs", "climb_stats",
                                 "placements", "holes", "placement_roles", "leds"]
    /// Sanity cap so a user can't point us at a 4 GB file by mistake (the full Aurora DB is ~70 MB).
    static let maxBytes: Int64 = 512 * 1_000_000

    static func validate(_ url: URL) throws -> Validated {
        let sizeBytes = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? UInt64) ?? 0)
        if sizeBytes > maxBytes { throw Failure.tooLarge(sizeBytes) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure.unreadable
        }
        defer { sqlite3_close(db) }

        let present = tableNames(db)
        let missing = requiredTables.filter { !present.contains($0) }
        if !missing.isEmpty { throw Failure.missingTables(missing) }

        let climbCount = scalarInt(db, "SELECT COUNT(*) FROM climbs WHERE is_listed = 1")
        if climbCount == 0 { throw Failure.noClimbs }
        let statCount = scalarInt(db, "SELECT COUNT(*) FROM climb_stats")
        let gradeCount = scalarInt(db, "SELECT COUNT(*) FROM difficulty_grades")
        let marker = scalarText(db, "SELECT MAX(created_at) FROM climbs") ?? ""

        // A stable, derived version: row-count fingerprint + a hash over the counts and the newest
        // climb's timestamp. Two installs of the same catalog produce the same version; a refreshed
        // catalog changes it. Not a real schema version — just an identity for "what's installed".
        let version = "c\(climbCount)·s\(statCount)·g\(gradeCount)·"
            + fnv1aHex("\(climbCount)|\(statCount)|\(gradeCount)|\(marker)")
        return Validated(version: version, climbCount: climbCount, sizeBytes: sizeBytes)
    }

    // MARK: - tiny sqlite helpers (read-only, mirror KilterCatalog's style)

    private static func tableNames(_ db: OpaquePointer?) -> Set<String> {
        var out: Set<String> = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1,
                                 &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    private static func scalarInt(_ db: OpaquePointer?, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private static func scalarText(_ db: OpaquePointer?, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private static func fnv1aHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
