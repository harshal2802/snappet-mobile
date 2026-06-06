import Foundation
import SQLite3

/// Read-only access layer over the **user-installed** `kilter.sqlite3` catalog, opened from
/// `KilterCatalogStore` (the app ships no catalog — issue #42; the user imports one themselves). This
/// is static reference data — opened read-only, never written, and kept out of SwiftData (which owns
/// user data). All queries are synchronous over a small DB; cheap enough to call from the main actor
/// like reading a plist.
///
/// On-device only: the reader never touches a network. When nothing is installed (or the file is
/// corrupt) it degrades to an empty catalog (`isAvailable == false`) and the module shows the opt-in
/// `KilterCatalogSyncView` rather than crashing the suite. Re-open after an install/remove via
/// `reload()` (the Kilter screens call it on `KilterCatalogStore.didChangeNotification`).
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

    /// Open the user-installed catalog from `KilterCatalogStore`. When nothing is installed, `db`
    /// stays nil and `isAvailable` is false (the module shows the opt-in sync screen).
    private func open() {
        let store = KilterCatalogStore.shared
        guard store.isInstalled,
              sqlite3_open_v2(store.resolvedCatalogURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            db = nil
            return
        }
        loadReference()
        isAvailable = !grades.isEmpty
    }

    /// Re-open after the installed catalog changes (import or remove). Main-thread only, per this
    /// type's convention — the Kilter screens call it when `KilterCatalogStore.didChangeNotification`
    /// fires. Clears every cache so geometry/grades from a previous catalog can't leak through.
    func reload() {
        if db != nil { sqlite3_close(db); db = nil }
        isAvailable = false
        grades.removeAll(); roleScreenColor.removeAll()
        placementXY.removeAll(); placementHole.removeAll()
        extentCache.removeAll(); geometryCache.removeAll(); ledCache.removeAll()
        open()
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

    /// Listed layouts that actually have climbs in the installed catalog, in catalog order.
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
        list(KilterFilter(layoutId: layoutId, angle: angle,
                          minDifficulty: minDifficulty, maxDifficulty: maxDifficulty), limit: limit)
    }

    /// Catalog list driven by the full `KilterFilter` — layout/angle/grade plus free-text search
    /// (name or setter), a benchmark/"classics" toggle, minimum ascents/quality, and a sort order.
    func list(_ f: KilterFilter, limit: Int = 500) -> [KilterListItem] {
        let lo = min(f.minDifficulty, f.maxDifficulty), hi = max(f.minDifficulty, f.maxDifficulty)
        let term = f.search.trimmingCharacters(in: .whitespacesAndNewlines)

        var sql = """
            SELECT c.uuid, c.name, c.setter_username, cs.display_difficulty,
                   cs.quality_average, cs.ascensionist_count
            FROM climbs c
            JOIN climb_stats cs ON cs.climb_uuid = c.uuid AND cs.angle = ?
            WHERE c.is_listed = 1 AND c.layout_id = ?
              AND cs.display_difficulty BETWEEN ? AND ?
              AND cs.ascensionist_count >= ?
              AND cs.quality_average >= ?
        """
        if !term.isEmpty { sql += " AND (c.name LIKE ? OR c.setter_username LIKE ?)" }
        if f.benchmarksOnly { sql += " AND cs.benchmark_difficulty IS NOT NULL" }
        sql += " ORDER BY \(f.sort.orderBy) LIMIT ?"   // sort is an enum-controlled clause (no injection)

        var out: [KilterListItem] = []
        query(sql, bind: { s in
            var i: Int32 = 1
            sqlite3_bind_int64(s, i, Int64(f.angle)); i += 1
            sqlite3_bind_int64(s, i, Int64(f.layoutId)); i += 1
            sqlite3_bind_double(s, i, lo); i += 1
            sqlite3_bind_double(s, i, hi); i += 1
            sqlite3_bind_int64(s, i, Int64(f.minAscents)); i += 1
            sqlite3_bind_double(s, i, f.minQuality); i += 1
            if !term.isEmpty {
                let like = "%\(term)%"
                sqlite3_bind_text(s, i, like, -1, Self.transient); i += 1
                sqlite3_bind_text(s, i, like, -1, Self.transient); i += 1
            }
            sqlite3_bind_int64(s, i, Int64(limit))
        }) { s in
            out.append(self.listItem(s))
        }
        return out
    }

    /// A random climb matching the current filter (Discovery "Surprise me").
    func randomClimb(_ filter: KilterFilter) -> KilterListItem? {
        list(filter, limit: 500).randomElement()
    }

    /// A deterministic "climb of the day" — a popular classic for the layout/angle, rotating daily.
    func climbOfTheDay(layoutId: Int, angle: Int) -> KilterListItem? {
        var pool = list(KilterFilter(layoutId: layoutId, angle: angle, minDifficulty: 1,
                                     maxDifficulty: 39, sort: .popular, benchmarksOnly: true), limit: 150)
        if pool.isEmpty {   // some layouts have few benchmarks — fall back to most-climbed
            pool = list(KilterFilter(layoutId: layoutId, angle: angle, minDifficulty: 1,
                                     maxDifficulty: 39, sort: .popular), limit: 150)
        }
        guard !pool.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        return pool[day % pool.count]
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
    ///
    /// Holds are normalized against the **whole board's** hole extent for the climb's layout (not the
    /// climb's own `edge_*` bounds), so every climb renders at the same scale and the lit holds line
    /// up exactly with the faint grid from `boardGeometry(forLayout:)`.
    func holds(for climb: KilterClimb) -> [KilterHold] {
        let e = extent(forLayout: climb.layoutId)
        let w = Double(e.maxX - e.minX), h = Double(e.maxY - e.minY)
        guard w > 0, h > 0 else { return [] }
        let leds = ledPositions(forLayout: climb.layoutId)
        var out: [KilterHold] = []
        for (placementId, roleId) in Self.parseFrames(climb.frames) {
            guard let (bx, by) = placementXY[placementId] else { continue }
            let nx = (Double(bx) - Double(e.minX)) / w
            let ny = (Double(by) - Double(e.minY)) / h
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

    // MARK: - Board geometry (the faint full-grid backdrop)

    /// `layout_id -> (minX,maxX,minY,maxY)` board-coordinate extent of every placement on the layout.
    private var extentCache: [Int: (minX: Int, maxX: Int, minY: Int, maxY: Int)] = [:]
    private var geometryCache: [Int: KilterBoardGeometry] = [:]

    private func extent(forLayout layoutId: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        if let c = extentCache[layoutId] { return c }
        var e = (minX: 0, maxX: 1, minY: 0, maxY: 1)
        query("""
            SELECT MIN(h.x), MAX(h.x), MIN(h.y), MAX(h.y)
            FROM placements p JOIN holes h ON h.id = p.hole_id WHERE p.layout_id = ?
        """, bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            if sqlite3_column_type(s, 0) != SQLITE_NULL {
                e = (Self.int(s, 0), Self.int(s, 1), Self.int(s, 2), Self.int(s, 3))
            }
        }
        extentCache[layoutId] = e
        return e
    }

    /// The board's drawable geometry: aspect ratio + the full normalized hole grid (deduped by hole),
    /// so the render shows the whole wall with the climb's holds highlighted on top.
    func boardGeometry(forLayout layoutId: Int) -> KilterBoardGeometry {
        if let c = geometryCache[layoutId] { return c }
        let e = extent(forLayout: layoutId)
        let w = Double(e.maxX - e.minX), h = Double(e.maxY - e.minY)
        guard w > 0, h > 0 else { return .empty }
        var grid: [KilterGridHole] = []
        var seen = Set<Int>()   // hole_id, to dedupe placements sharing a hole
        query("""
            SELECT DISTINCT p.hole_id, h.x, h.y
            FROM placements p JOIN holes h ON h.id = p.hole_id WHERE p.layout_id = ?
        """, bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            let hole = Self.int(s, 0)
            guard seen.insert(hole).inserted else { return }
            let nx = (Double(Self.int(s, 1)) - Double(e.minX)) / w
            let ny = (Double(Self.int(s, 2)) - Double(e.minY)) / h
            grid.append(KilterGridHole(x: nx, y: 1 - ny))
        }
        let geo = KilterBoardGeometry(aspect: w / h, grid: grid)
        geometryCache[layoutId] = geo
        return geo
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
