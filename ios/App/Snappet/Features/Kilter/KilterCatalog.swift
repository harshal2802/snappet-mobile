import Foundation
import SQLite3

/// Read-only access layer over the bundled `kilter.sqlite3` catalog (built by
/// `tools/kilter/build_bundled_db.py`). This is **static reference data** — opened read-only, never
/// written, and kept out of SwiftData (which owns user data). All queries are synchronous over a
/// small bundled DB (≈800 climbs); cheap enough to call from the main actor like reading a plist.
///
/// On-device only: no network, ever. A missing/corrupt asset degrades to an empty catalog rather
/// than crashing the suite.
///
/// Used exclusively from the main thread (the Kilter views), so it isn't `@MainActor`-isolated —
/// that would make `KilterCatalog.shared` unusable in the views' stored-property initializers. The
/// `nonisolated(unsafe)` singleton is safe under that main-thread-only convention.
final class KilterCatalog {
    nonisolated(unsafe) static let shared = KilterCatalog()

    private var db: OpaquePointer?
    /// `placement_id -> (boardX, boardY)` for every placement (loaded once; ~3.7k rows).
    private var placementXY: [Int: (x: Int, y: Int)] = [:]
    private var placementHole: [Int: Int] = [:]
    /// `role_id -> screen color hex`.
    private var roleScreenColor: [Int: String] = [:]
    /// `difficulty (rounded) -> grade label` (e.g. 16 -> "6a/V3").
    private var grades: [Int: String] = [:]

    /// True when the catalog asset opened successfully and has climbs.
    private(set) var isAvailable = false

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() { open() }

    private func open() {
        guard let url = Bundle.main.url(forResource: "kilter", withExtension: "sqlite3"),
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            db = nil
            return
        }
        loadReference()
        isAvailable = !grades.isEmpty
    }

    // MARK: - Reference data (loaded once)

    private func loadReference() {
        query("SELECT difficulty, boulder_name FROM difficulty_grades") { s in
            self.grades[Self.int(s, 0)] = Self.text(s, 1)
        }
        query("SELECT id, screen_color FROM placement_roles") { s in
            self.roleScreenColor[Self.int(s, 0)] = Self.text(s, 1)
        }
        query("SELECT p.id, h.x, h.y, p.hole_id FROM placements p JOIN holes h ON h.id = p.hole_id") { s in
            let pid = Self.int(s, 0)
            self.placementXY[pid] = (Self.int(s, 1), Self.int(s, 2))
            self.placementHole[pid] = Self.int(s, 3)
        }
    }

    // MARK: - Public reads

    /// Listed layouts that actually have climbs in the bundled catalog, in catalog order.
    func layouts() -> [KilterLayout] {
        var out: [KilterLayout] = []
        query("""
            SELECT l.id, l.name FROM layouts l
            WHERE l.id IN (SELECT DISTINCT layout_id FROM climbs WHERE is_listed = 1)
            ORDER BY l.id
        """) { s in
            out.append(KilterLayout(id: Self.int(s, 0), name: Self.text(s, 1)))
        }
        return out
    }

    /// Distinct angles available across the catalog (0…70 in 5° steps).
    func angles() -> [Int] {
        var out: [Int] = []
        query("SELECT DISTINCT angle FROM climb_stats ORDER BY angle") { s in
            out.append(Self.int(s, 0))
        }
        return out
    }

    /// Catalog list for one layout at one angle, filtered by a difficulty range, most-climbed first.
    func list(layoutId: Int, angle: Int, minDifficulty: Double, maxDifficulty: Double,
              limit: Int = 500) -> [KilterListItem] {
        var out: [KilterListItem] = []
        query("""
            SELECT c.uuid, c.name, c.setter_username, cs.display_difficulty,
                   cs.quality_average, cs.ascensionist_count
            FROM climbs c
            JOIN climb_stats cs ON cs.climb_uuid = c.uuid AND cs.angle = ?
            WHERE c.is_listed = 1 AND c.layout_id = ?
              AND cs.display_difficulty BETWEEN ? AND ?
            ORDER BY cs.ascensionist_count DESC
            LIMIT ?
        """, bind: { s in
            sqlite3_bind_int64(s, 1, Int64(angle))
            sqlite3_bind_int64(s, 2, Int64(layoutId))
            sqlite3_bind_double(s, 3, minDifficulty)
            sqlite3_bind_double(s, 4, maxDifficulty)
            sqlite3_bind_int64(s, 5, Int64(limit))
        }) { s in
            out.append(self.listItem(s))
        }
        return out
    }

    /// Fetch a set of climbs by uuid (used to render the favorites list), preserving input order.
    func climbsByUUID(_ uuids: [String]) -> [KilterListItem] {
        guard !uuids.isEmpty else { return [] }
        var out: [KilterListItem] = []
        for uuid in uuids {
            query("""
                SELECT c.uuid, c.name, c.setter_username, cf.display_difficulty,
                       cf.quality_average, cf.ascensionist_count
                FROM climbs c
                LEFT JOIN climb_cache_fields cf ON cf.climb_uuid = c.uuid
                WHERE c.uuid = ?
            """, bind: { s in
                sqlite3_bind_text(s, 1, uuid, -1, Self.transient)
            }) { s in
                out.append(self.listItem(s))
            }
        }
        return out
    }

    private func listItem(_ s: OpaquePointer?) -> KilterListItem {
        let diff = sqlite3_column_double(s, 3)
        return KilterListItem(
            uuid: Self.text(s, 0), name: Self.text(s, 1), setter: Self.text(s, 2),
            difficulty: diff, gradeLabel: gradeLabel(diff),
            quality: sqlite3_column_double(s, 4), ascents: Self.int(s, 5))
    }

    func climb(_ uuid: String) -> KilterClimb? {
        var result: KilterClimb?
        query("""
            SELECT uuid, name, setter_username, layout_id,
                   edge_left, edge_right, edge_bottom, edge_top, frames
            FROM climbs WHERE uuid = ?
        """, bind: { s in
            sqlite3_bind_text(s, 1, uuid, -1, Self.transient)
        }) { s in
            result = KilterClimb(
                uuid: Self.text(s, 0), name: Self.text(s, 1), setter: Self.text(s, 2),
                layoutId: Self.int(s, 3),
                edgeLeft: Self.int(s, 4), edgeRight: Self.int(s, 5),
                edgeBottom: Self.int(s, 6), edgeTop: Self.int(s, 7),
                frames: Self.text(s, 8))
        }
        return result
    }

    func stats(_ uuid: String) -> [KilterClimbStat] {
        var out: [KilterClimbStat] = []
        query("""
            SELECT angle, display_difficulty, benchmark_difficulty,
                   ascensionist_count, quality_average, fa_username
            FROM climb_stats WHERE climb_uuid = ? ORDER BY angle
        """, bind: { s in
            sqlite3_bind_text(s, 1, uuid, -1, Self.transient)
        }) { s in
            out.append(KilterClimbStat(
                angle: Self.int(s, 0),
                difficulty: sqlite3_column_double(s, 1),
                benchmarkDifficulty: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : sqlite3_column_double(s, 2),
                ascents: Self.int(s, 3),
                quality: sqlite3_column_double(s, 4),
                faUsername: Self.text(s, 5)))
        }
        return out
    }

    func betaLinks(_ uuid: String) -> [String] {
        var out: [String] = []
        query("SELECT link FROM beta_links WHERE climb_uuid = ? AND is_listed = 1", bind: { s in
            sqlite3_bind_text(s, 1, uuid, -1, Self.transient)
        }) { s in
            out.append(Self.text(s, 0))
        }
        return out
    }

    /// Decode a climb's `frames` into positioned, colored holds for rendering / illumination.
    func holds(for climb: KilterClimb) -> [KilterHold] {
        let w = Double(climb.edgeRight - climb.edgeLeft)
        let h = Double(climb.edgeTop - climb.edgeBottom)
        guard w > 0, h > 0 else { return [] }
        let leds = ledPositions(forLayout: climb.layoutId)
        var out: [KilterHold] = []
        for (placementId, roleId) in Self.parseFrames(climb.frames) {
            guard let (bx, by) = placementXY[placementId] else { continue }
            let nx = (Double(bx) - Double(climb.edgeLeft)) / w
            let ny = (Double(by) - Double(climb.edgeBottom)) / h
            out.append(KilterHold(
                placementId: placementId,
                x: min(max(nx, 0), 1),
                y: 1 - min(max(ny, 0), 1),   // board y is bottom-up; view y is top-down
                colorHex: roleScreenColor[roleId] ?? "FFFFFF",
                role: Self.roleName(roleId),
                ledPosition: placementHole[placementId].flatMap { leds[$0] }))
        }
        return out
    }

    /// `difficulty (float) -> grade label`, rounding to the nearest catalog grade.
    func gradeLabel(_ difficulty: Double) -> String {
        grades[Int(difficulty.rounded())] ?? "—"
    }

    /// All listed grade labels in difficulty order (for the filter UI).
    func gradeScale() -> [(difficulty: Int, label: String)] {
        grades.keys.sorted().map { ($0, grades[$0]!) }
    }

    // MARK: - LED mapping (per layout, for BLE)

    private var ledCache: [Int: [Int: Int]] = [:]   // layoutId -> (holeId -> led position)
    private func ledPositions(forLayout layoutId: Int) -> [Int: Int] {
        if let cached = ledCache[layoutId] { return cached }
        var sizeId = 0
        query("SELECT MIN(product_size_id) FROM product_sizes_layouts_sets WHERE layout_id = ?",
              bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            sizeId = Self.int(s, 0)
        }
        var map: [Int: Int] = [:]
        query("SELECT hole_id, position FROM leds WHERE product_size_id = ?",
              bind: { s in sqlite3_bind_int64(s, 1, Int64(sizeId)) }) { s in
            map[Self.int(s, 0)] = Self.int(s, 1)
        }
        ledCache[layoutId] = map
        return map
    }

    // MARK: - Frame parsing

    /// Parse `p<placement>r<role>` tokens into `(placementId, roleId)` pairs.
    static func parseFrames(_ frames: String) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for token in frames.split(separator: "p") where !token.isEmpty {
            let parts = token.split(separator: "r")
            guard parts.count == 2, let p = Int(parts[0]), let r = Int(parts[1]) else { continue }
            out.append((p, r))
        }
        return out
    }

    private static func roleName(_ roleId: Int) -> String {
        switch roleId {
        case 12, 42: return "start"
        case 13, 43: return "middle"
        case 14, 44: return "finish"
        case 15, 45: return "foot"
        default: return "hold"
        }
    }

    // MARK: - tiny sqlite helpers

    private func query(_ sql: String,
                       bind: ((OpaquePointer?) -> Void)? = nil,
                       step: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { step(stmt) }
    }

    private static func text(_ s: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(s, col) else { return "" }
        return String(cString: c)
    }

    private static func int(_ s: OpaquePointer?, _ col: Int32) -> Int {
        Int(sqlite3_column_int64(s, col))
    }
}
