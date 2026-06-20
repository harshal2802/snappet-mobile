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
    /// `role_id -> screen color hex` (for the on-screen render).
    private var roleScreenColor: [Int: String] = [:]
    /// `role_id -> LED color hex` (`placement_roles.led_color` — what the physical board should show;
    /// differs from `screen_color` for some roles, e.g. start is `00FF00` LED vs `00DD00` on screen).
    private var roleLedColor: [Int: String] = [:]
    /// `difficulty (rounded) -> grade label` (e.g. 16 -> "6a/V3").
    private var grades: [Int: String] = [:]

    /// True when the catalog asset opened successfully and has climbs.
    private(set) var isAvailable = false

    /// Whether the installed catalog carries the newer optional columns. Detected once on open so reads
    /// can prefer them and degrade gracefully on older/hand-rolled catalogs that lack them.
    private var hasNoMatchColumn = false       // climbs.is_nomatch (the "No matching" rule)
    private var hasSizeEdges = false           // product_sizes.edge_* (a board size's fit box)

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
        hasNoMatchColumn = false; hasSizeEdges = false
        grades.removeAll(); roleScreenColor.removeAll(); roleLedColor.removeAll()
        placementXY.removeAll(); placementHole.removeAll()
        renderCache.removeAll(); ledCache.removeAll(); sizesCache.removeAll()
        open()
    }

    // MARK: - Reference data (loaded once)

    private func loadReference() {
        query("SELECT difficulty, boulder_name FROM difficulty_grades") { s in
            self.grades[Self.int(s, 0)] = Self.text(s, 1)
        }
        query("SELECT id, screen_color, led_color FROM placement_roles") { s in
            self.roleScreenColor[Self.int(s, 0)] = Self.text(s, 1)
            self.roleLedColor[Self.int(s, 0)] = Self.text(s, 2)
        }
        query("SELECT p.id, h.x, h.y, p.hole_id FROM placements p JOIN holes h ON h.id = p.hole_id") { s in
            let pid = Self.int(s, 0)
            self.placementXY[pid] = (Self.int(s, 1), Self.int(s, 2))
            self.placementHole[pid] = Self.int(s, 3)
        }
        hasNoMatchColumn = columnExists("climbs", "is_nomatch")
        hasSizeEdges = columnExists("product_sizes", "edge_left")
    }

    /// Whether `table` has `column` — used to read newer optional columns only when the installed
    /// catalog has them (PRAGMA table_info row layout: cid, name, type, …).
    private func columnExists(_ table: String, _ column: String) -> Bool {
        var found = false
        query("PRAGMA table_info(\(table))") { s in
            if Self.text(s, 1) == column { found = true }
        }
        return found
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

    /// How many climbs match the full filter (search + grade + extras) — no list LIMIT, for the live
    /// "N climbs" count in the browse bar. Mirrors `list`'s WHERE exactly (one `climb_stats` row per
    /// climb at the angle, so `COUNT(*)` = distinct matching climbs).
    func count(_ f: KilterFilter) -> Int {
        let lo = min(f.minDifficulty, f.maxDifficulty), hi = max(f.minDifficulty, f.maxDifficulty)
        let term = f.search.trimmingCharacters(in: .whitespacesAndNewlines)
        var sql = """
            SELECT COUNT(*) FROM climbs c
            JOIN climb_stats cs ON cs.climb_uuid = c.uuid AND cs.angle = ?
            WHERE c.is_listed = 1 AND c.layout_id = ?
              AND cs.display_difficulty BETWEEN ? AND ?
              AND cs.ascensionist_count >= ?
              AND cs.quality_average >= ?
        """
        if !term.isEmpty { sql += " AND (c.name LIKE ? OR c.setter_username LIKE ?)" }
        if f.benchmarksOnly { sql += " AND cs.benchmark_difficulty IS NOT NULL" }
        var result = 0
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
        }) { s in result = Self.int(s, 0) }
        return result
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
        // Read `is_nomatch` (the "No matching" rule) when the catalog has the column; older catalogs
        // lack it, so fall back to detecting the setter note in `description`.
        let nm = hasNoMatchColumn ? ", is_nomatch" : ""
        query("""
            SELECT uuid, name, setter_username, layout_id,
                   edge_left, edge_right, edge_bottom, edge_top, frames, description\(nm)
            FROM climbs WHERE uuid = ?
        """, bind: { s in
            sqlite3_bind_text(s, 1, uuid, -1, Self.transient)
        }) { s in
            let description = Self.text(s, 9)
            let isNoMatch = hasNoMatchColumn ? (Self.int(s, 10) != 0)
                                             : kilterDescriptionForbidsMatching(description)
            result = KilterClimb(
                uuid: Self.text(s, 0), name: Self.text(s, 1), setter: Self.text(s, 2),
                layoutId: Self.int(s, 3),
                edgeLeft: Self.int(s, 4), edgeRight: Self.int(s, 5),
                edgeBottom: Self.int(s, 6), edgeTop: Self.int(s, 7),
                frames: Self.text(s, 8), description: description, isNoMatch: isNoMatch)
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
    /// Holds are normalized against the **render extent** for the climb's layout *at `sizeId`* (the
    /// holes physically wired on that board size — see `renderHoles`), not the climb's own `edge_*`
    /// bounds, so the lit holds line up exactly with the faint grid from `boardGeometry(forLayout:sizeId:)`
    /// at the same size. Picking a smaller board reshapes both, together. (`sizeId 0` → the whole layout.)
    /// `sizeId` also selects which `leds` mapping to use for the LED *address* — **critical**, since the
    /// same hole has a *different* LED address on each board size, so an arbitrary/wrong size lights the
    /// wrong holds. When `sizeId` is `0` or not valid for this layout, the address falls back to the
    /// layout's smallest size.
    func holds(for climb: KilterClimb, sizeId: Int = 0) -> [KilterHold] {
        // Resolve a stale/foreign size to the layout's default once, so the render basis and the LED
        // address always agree (a foreign size would otherwise render whole-layout while lighting the
        // default board). `sizeId 0` stays the explicit "whole layout" basis for legacy callers.
        let eff = effectiveSizeId(forLayout: climb.layoutId, requested: sizeId)
        let r = renderHoles(forLayout: climb.layoutId, sizeId: sizeId == 0 ? 0 : eff)
        let w = Double(r.maxX - r.minX), h = Double(r.maxY - r.minY)
        guard w > 0, h > 0 else { return [] }
        let leds = ledPositions(forSize: eff)
        var out: [KilterHold] = []
        for (placementId, roleId) in Self.parseFrames(climb.frames) {
            guard let (bx, by) = placementXY[placementId] else { continue }
            let nx = (Double(bx) - Double(r.minX)) / w
            let ny = (Double(by) - Double(r.minY)) / h
            let screen = roleScreenColor[roleId] ?? "FFFFFF"
            out.append(KilterHold(
                placementId: placementId,
                x: min(max(nx, 0), 1),
                y: 1 - min(max(ny, 0), 1),   // board y is bottom-up; view y is top-down
                colorHex: screen,
                ledColorHex: roleLedColor[roleId] ?? screen,
                role: Self.roleName(roleId),
                ledPosition: placementHole[placementId].flatMap { leds[$0] }))
        }
        return out
    }

    // MARK: - Board geometry (the size-accurate full-grid backdrop)

    /// The render basis for one `(layout, size)`: the board-coordinate extent + the normalized hole grid
    /// of the holes that physically exist on that board size. The schematic and the lit holds both
    /// normalize to this, so picking a smaller board reshapes both together.
    private struct RenderHoles { let minX, maxX, minY, maxY: Int; let grid: [KilterGridHole] }
    /// `"<layout>#<size>" -> RenderHoles` (size 0 = whole layout).
    private var renderCache: [String: RenderHoles] = [:]

    private static func renderKey(_ layoutId: Int, _ sizeId: Int) -> String { "\(layoutId)#\(sizeId)" }

    /// Compute (and cache) the render basis for a `(layout, size)`. The visible board for a `product_size`
    /// is exactly the holes wired for it in the `leds` table — that's the physical board's hole set, so a
    /// 7×10 reads shorter than a 12×14. `sizeId <= 0`, or a size with no `leds` rows for this layout
    /// (older/hand-rolled catalog), falls back to the **whole layout** so behavior degrades, never crashes.
    private func renderHoles(forLayout layoutId: Int, sizeId: Int) -> RenderHoles {
        let key = Self.renderKey(layoutId, sizeId)
        if let c = renderCache[key] { return c }
        // Holes wired for this size (the LED map's keys); empty → no size filter (whole layout).
        let sizeHoles: Set<Int> = sizeId > 0 ? Set(ledPositions(forSize: sizeId).keys) : []
        // The layout's holes (deduped by hole_id).
        var pts: [(hole: Int, x: Int, y: Int)] = []
        var seen = Set<Int>()
        query("""
            SELECT DISTINCT p.hole_id, h.x, h.y
            FROM placements p JOIN holes h ON h.id = p.hole_id WHERE p.layout_id = ?
        """, bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            let hole = Self.int(s, 0)
            guard seen.insert(hole).inserted else { return }
            pts.append((hole, Self.int(s, 1), Self.int(s, 2)))
        }
        // Keep only the size's holes — but only if that filter actually selects some of this layout's
        // holes; otherwise (size has no leds for the layout) fall back to the whole layout.
        var kept = pts
        if !sizeHoles.isEmpty {
            let f = pts.filter { sizeHoles.contains($0.hole) }
            if !f.isEmpty { kept = f }
        }
        guard let minX = kept.map(\.x).min(), let maxX = kept.map(\.x).max(),
              let minY = kept.map(\.y).min(), let maxY = kept.map(\.y).max(),
              maxX > minX, maxY > minY else {
            let empty = RenderHoles(minX: 0, maxX: 1, minY: 0, maxY: 1, grid: [])
            renderCache[key] = empty
            return empty
        }
        let w = Double(maxX - minX), h = Double(maxY - minY)
        let grid = kept.map {
            KilterGridHole(x: (Double($0.x) - Double(minX)) / w,
                           y: 1 - (Double($0.y) - Double(minY)) / h)   // board y is bottom-up; view y top-down
        }
        let out = RenderHoles(minX: minX, maxX: maxX, minY: minY, maxY: maxY, grid: grid)
        renderCache[key] = out
        return out
    }

    /// The board's drawable geometry **at the chosen size**: aspect ratio + the normalized hole grid
    /// (deduped by hole), so the render shows the right physical board with the climb's holds on top.
    /// `sizeId 0` (default) renders the whole layout — older callers keep their behavior.
    func boardGeometry(forLayout layoutId: Int, sizeId: Int = 0) -> KilterBoardGeometry {
        let r = renderHoles(forLayout: layoutId, sizeId: sizeId)
        let w = Double(r.maxX - r.minX), h = Double(r.maxY - r.minY)
        guard w > 0, h > 0 else { return .empty }
        return KilterBoardGeometry(aspect: w / h, grid: r.grid)
    }

    /// `difficulty (float) -> grade label`, rounding to the nearest catalog grade.
    func gradeLabel(_ difficulty: Double) -> String {
        grades[Int(difficulty.rounded())] ?? "—"
    }

    /// All listed grade labels in difficulty order (for the filter UI).
    func gradeScale() -> [(difficulty: Int, label: String)] {
        grades.keys.sorted().map { ($0, grades[$0]!) }
    }

    // MARK: - Board sizes & LED mapping (per product size, for BLE)

    private var ledCache: [Int: [Int: Int]] = [:]    // product_size_id -> (holeId -> led position)
    private var sizesCache: [Int: [KilterBoardSize]] = [:]   // layoutId -> available sizes

    /// The physical board sizes available for a layout (e.g. Original → 7×10, 8×12, 12×14, …). The user
    /// picks theirs in Settings; the choice drives `holds(for:sizeId:)` so the right LEDs light. Ordered
    /// by `product_size_id` (the catalog's own order). Falls back to bare ids if `product_sizes` is
    /// absent (older catalog), so the picker still works.
    func sizes(forLayout layoutId: Int) -> [KilterBoardSize] {
        if let cached = sizesCache[layoutId] { return cached }
        var out: [KilterBoardSize] = []
        // Pull the size's fit box (`edge_*`) only when the catalog carries those columns (real Aurora
        // data); older/hand-rolled catalogs omit them → a nil box (the size filter simply won't apply).
        let edges = hasSizeEdges ? ", ps.edge_left, ps.edge_right, ps.edge_bottom, ps.edge_top" : ""
        query("""
            SELECT ps.id, ps.name, COALESCE(ps.description, '')\(edges)
            FROM product_sizes ps
            WHERE ps.id IN (SELECT product_size_id FROM product_sizes_layouts_sets WHERE layout_id = ?)
            ORDER BY ps.id
        """, bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            let box = hasSizeEdges ? KilterSizeBox(left: Self.int(s, 3), right: Self.int(s, 4),
                                                   bottom: Self.int(s, 5), top: Self.int(s, 6)) : nil
            out.append(KilterBoardSize(id: Self.int(s, 0), name: Self.text(s, 1),
                                       detail: Self.text(s, 2), box: box))
        }
        if out.isEmpty {
            query("SELECT DISTINCT product_size_id FROM product_sizes_layouts_sets WHERE layout_id = ? "
                  + "ORDER BY product_size_id", bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
                out.append(KilterBoardSize(id: Self.int(s, 0), name: "Size \(Self.int(s, 0))", detail: "", box: nil))
            }
        }
        sizesCache[layoutId] = out
        return out
    }

    /// The default size for a layout when the user hasn't chosen one — the smallest `product_size_id`,
    /// matching the catalog's natural order. (Selection still beats this; it only seeds the picker.)
    func defaultSizeId(forLayout layoutId: Int) -> Int { sizes(forLayout: layoutId).map(\.id).min() ?? 0 }

    /// Resolve the size to actually use: the requested one if it's valid for this layout, else the
    /// layout's default. Guards against a stale preference (e.g. a size from another layout). Used by the
    /// detail render and by P1's board-memory restore (a remembered size must still be valid for its
    /// remembered layout).
    func effectiveSizeId(forLayout layoutId: Int, requested: Int) -> Int {
        let ids = sizes(forLayout: layoutId).map(\.id)
        return ids.contains(requested) ? requested : (ids.min() ?? 0)
    }

    private func ledPositions(forSize sizeId: Int) -> [Int: Int] {
        if let cached = ledCache[sizeId] { return cached }
        var map: [Int: Int] = [:]
        query("SELECT hole_id, position FROM leds WHERE product_size_id = ?",
              bind: { s in sqlite3_bind_int64(s, 1, Int64(sizeId)) }) { s in
            map[Self.int(s, 0)] = Self.int(s, 1)
        }
        ledCache[sizeId] = map
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

    // MARK: - Authoring support (manual editor + duplicate detection)

    /// Tappable placement targets for the authoring board at a `(layout, size)` — one placement per hole,
    /// normalized to the **same render extent** as `holds(for:sizeId:)`, so the editor's targets line up
    /// exactly with the faint grid (and any lit holds). Falls back to the whole layout when the size has
    /// no `leds` rows for it (same robustness as `renderHoles`), so the editor is never empty.
    func placeableHolds(forLayout layoutId: Int, sizeId: Int = 0) -> [KilterPlaceableHold] {
        let eff = effectiveSizeId(forLayout: layoutId, requested: sizeId)
        let r = renderHoles(forLayout: layoutId, sizeId: sizeId == 0 ? 0 : eff)
        let w = Double(r.maxX - r.minX), h = Double(r.maxY - r.minY)
        guard w > 0, h > 0 else { return [] }
        let sizeHoles: Set<Int> = sizeId > 0 ? Set(ledPositions(forSize: eff).keys) : []

        var rows: [(pid: Int, hole: Int, x: Int, y: Int)] = []
        query("""
            SELECT p.id, p.hole_id, h.x, h.y
            FROM placements p JOIN holes h ON h.id = p.hole_id
            WHERE p.layout_id = ? ORDER BY p.id
        """, bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            rows.append((Self.int(s, 0), Self.int(s, 1), Self.int(s, 2), Self.int(s, 3)))
        }
        // Keep only the size's holes — but only if that filter selects some of this layout's holes;
        // otherwise (size has no leds for the layout) keep the whole layout.
        var kept = rows
        if !sizeHoles.isEmpty {
            let f = rows.filter { sizeHoles.contains($0.hole) }
            if !f.isEmpty { kept = f }
        }
        var out: [KilterPlaceableHold] = []
        var seenHole = Set<Int>()
        for row in kept where seenHole.insert(row.hole).inserted {   // one placement per hole
            let nx = (Double(row.x) - Double(r.minX)) / w
            let ny = (Double(row.y) - Double(r.minY)) / h
            out.append(KilterPlaceableHold(placementId: row.pid, holeId: row.hole,
                                           x: min(max(nx, 0), 1), y: 1 - min(max(ny, 0), 1)))
        }
        return out
    }

    /// The hold bounding box (board units) spanned by a set of placements — the `edge_*` for an authored
    /// climb (drives the size-fit rule). `nil` when none of the placements is known to the catalog.
    func boardBounds(forPlacementIds ids: [Int]) -> KilterSizeBox? {
        let xs = ids.compactMap { placementXY[$0]?.x }
        let ys = ids.compactMap { placementXY[$0]?.y }
        guard let l = xs.min(), let rr = xs.max(), let b = ys.min(), let t = ys.max() else { return nil }
        return KilterSizeBox(left: l, right: rr, bottom: b, top: t)
    }

    /// Every climb for a layout reduced to what the duplicate check needs: `(uuid, name, setter, frames)`.
    /// Read straight from the read-only catalog; `KilterDuplicateChecker` canonicalizes + indexes them so
    /// an authored climb that matches an existing one (any hold order) is caught before it's saved.
    func climbFramesForDedup(forLayout layoutId: Int)
        -> [(uuid: String, name: String, setter: String, frames: String)] {
        var out: [(uuid: String, name: String, setter: String, frames: String)] = []
        query("SELECT uuid, name, setter_username, frames FROM climbs WHERE layout_id = ?",
              bind: { s in sqlite3_bind_int64(s, 1, Int64(layoutId)) }) { s in
            out.append((Self.text(s, 0), Self.text(s, 1), Self.text(s, 2), Self.text(s, 3)))
        }
        return out
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
