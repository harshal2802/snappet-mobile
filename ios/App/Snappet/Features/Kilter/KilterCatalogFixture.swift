import Foundation
import SQLite3

/// Builds a tiny, **fully-synthetic** Kilter catalog (zero Aurora data — a couple of invented layouts,
/// a small invented hole grid, four made-up climbs) for tests and the UI-test install path. Mirrors
/// `tools/kilter/build_test_fixture.py` and the Kotlin `KilterCatalogFixture`; keep the three in sync.
///
/// **Test support only.** `installForUITestingIfRequested()` runs ONLY under explicit launch arguments
/// (see `SnappetApp`), so a production launch never builds or installs anything — and because the rows
/// are authored here, no Aurora data ships in the binary. Unit tests call `temporaryBuild()` directly.
enum KilterCatalogFixture {
    private static let coords = [4, 8, 12, 16, 20]
    private static let createdAt = "2024-01-01 00:00:00"
    /// role id → (name, screen colour, LED colour). The reader maps 12/13/14/15 to
    /// start/middle/finish/foot. `start` deliberately has a different `led_color` vs `screen_color`
    /// (mirrors real Kilter data) so tests cover the board using `led_color`, not the on-screen colour.
    private static let roles: [(id: Int, name: String, screen: String, led: String)] = [
        (12, "start", "00DD00", "00FF00"), (13, "middle", "00FFFF", "00FFFF"),
        (14, "finish", "FF00FF", "FF00FF"), (15, "foot", "FFA500", "FFA500"),
    ]
    /// Two same-dimension board sizes for layout 1, so tests cover board-size LED selection. Size 1 maps
    /// hole H → LED position H; size 2 maps hole H → H + sizeTwoOffset (a different physical address),
    /// proving the wrong size lights the wrong holds.
    private static let sizeTwoOffset = 1000
    /// A third, genuinely SMALLER board (5×3) that wires only the bottom `sizeThreeRows` rows (holes
    /// 1–15), so tests can prove the render tracks the size: `boardGeometry(sizeId: 3)` is 16×8
    /// (aspect 2.0, 15 holes) vs the full 16×16 board (aspect 1.0, 25 holes).
    private static let sizeThreeRows = 3
    private static let sizeThreeOffset = 2000

    private struct Climb {
        let uuid, name, setter, frames: String
        let stats: [(angle: Int, diff: Double, ascents: Int, quality: Double)]
    }
    private static let climbs: [Climb] = [
        Climb(uuid: "11111111-1111-4111-8111-111111111111", name: "Test Problem Alpha",
              setter: "fixtureSetter", frames: "p1r12p13r13p25r14",
              stats: [(40, 15, 250, 2.6), (25, 12, 90, 2.1)]),
        Climb(uuid: "22222222-2222-4222-8222-222222222222", name: "Test Problem Bravo",
              setter: "fixtureSetter", frames: "p5r12p13r13p21r14",
              stats: [(40, 20, 120, 2.9), (30, 18, 60, 2.4)]),
        Climb(uuid: "33333333-3333-4333-8333-333333333333", name: "Test Problem Charlie",
              setter: "anotherSetter", frames: "p3r12p7r13p19r13p23r14",
              stats: [(40, 24, 45, 1.8)]),
        Climb(uuid: "44444444-4444-4444-8444-444444444444", name: "Test Problem Delta",
              setter: "anotherSetter", frames: "p2r12p14r13p24r14",
              stats: [(25, 10, 300, 3.0), (40, 16, 200, 2.7)]),
    ]

    enum Failure: Error { case cantCreate, exec(String) }

    /// Write the synthetic catalog to `url` (overwriting any existing file). Returns `url`.
    @discardableResult
    static func build(at url: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else { sqlite3_close(db); throw Failure.cantCreate }
        defer { sqlite3_close(db) }
        try exec(db, sql)
        return url
    }

    /// Build into a unique temp file (for unit tests / installer input).
    static func temporaryBuild() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilter-fixture-\(UUID().uuidString).sqlite3")
        return try build(at: url)
    }

    /// Test-only: under `-uiTestFreshStore`/`-uiTestInstallKilterCatalog` clear any leftover catalog so
    /// runs are deterministic, then (only with the install arg) build + install the fixture. A normal
    /// launch passes neither arg and this no-ops.
    static func installForUITestingIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let install = args.contains("-uiTestInstallKilterCatalog")
        guard install || args.contains("-uiTestFreshStore") else { return }

        // Deterministic browse state for UI tests. The Kilter filter prefs (angle/layout/grade) live in
        // `@AppStorage` → UserDefaults, which persists across simulator launches and `-uiTestFreshStore`
        // does NOT reset (it only swaps SwiftData to in-memory). The synthetic fixture only carries
        // climbs on layout 1 at angles 25/30/40, so a leftover angle from a prior run (e.g. 0, which the
        // old bundled Aurora catalog had but the fixture doesn't) would filter every climb out and the
        // browse list would read "No climbs match". Clear the keys so the view opens on the declared
        // defaults (angle 40 / layout 1 / grades 10–33) that the fixture covers.
        let defaults = UserDefaults.standard
        for key in ["kilter.angle", "kilter.layout", "kilter.minGrade", "kilter.maxGrade"] {
            defaults.removeObject(forKey: key)
        }

        try? KilterCatalogStore.shared.clear()
        guard install else { return }
        guard let url = try? temporaryBuild(),
              let validated = try? KilterCatalogValidator.validate(url) else { return }
        let meta = KilterCatalogMeta(version: validated.version, climbCount: validated.climbCount,
                                     sizeBytes: validated.sizeBytes, source: "Test fixture",
                                     installedAt: .now)
        try? KilterCatalogStore.shared.install(from: url, meta: meta)
    }

    // MARK: - SQL generation (mirrors the Python fixture exactly)

    private static var sql: String {
        var stmts: [String] = ddl

        for d in 1...39 {
            stmts.append("INSERT INTO difficulty_grades VALUES "
                + "(\(d),'\(d)a/V\(max(0, d / 3))','route\(d)',1)")
        }
        stmts.append("INSERT INTO layouts VALUES (1,1,'Test Wall A','',0,1,NULL,'\(createdAt)')")
        stmts.append("INSERT INTO layouts VALUES (2,1,'Test Wall B','',0,1,NULL,'\(createdAt)')")

        for role in roles {
            // placement_roles columns: id, product_id, position, name, full_name, led_color, screen_color
            stmts.append("INSERT INTO placement_roles VALUES "
                + "(\(role.id),1,\(role.id),'\(role.name)','\(role.name)','\(role.led)','\(role.screen)')")
        }

        stmts.append("INSERT INTO product_sizes VALUES (1,'5 x 5','Test Small')")
        stmts.append("INSERT INTO product_sizes VALUES (2,'5 x 5','Test Large')")
        stmts.append("INSERT INTO product_sizes VALUES (3,'5 x 3','Test Mini')")

        var holeID = 0
        for (row, y) in coords.enumerated() {
            for (col, x) in coords.enumerated() {
                holeID += 1
                let name = "\(Character(UnicodeScalar(65 + row)!))\(col + 1)"
                stmts.append("INSERT INTO holes VALUES (\(holeID),1,'\(name)',\(x),\(y),NULL,0)")
                stmts.append("INSERT INTO placements VALUES (\(holeID),1,\(holeID),\(holeID),0,NULL)")
                // Sizes 1/2 (same dimensions): hole H → position H, resp. H + offset (a different address).
                stmts.append("INSERT INTO leds VALUES (\(holeID),1,\(holeID),\(holeID))")
                stmts.append("INSERT INTO leds VALUES "
                    + "(\(holeID + 10000),2,\(holeID),\(holeID + sizeTwoOffset))")
                // Size 3 (the smaller board) wires only the bottom rows → it renders a shorter board.
                if row < sizeThreeRows {
                    stmts.append("INSERT INTO leds VALUES "
                        + "(\(holeID + 20000),3,\(holeID),\(holeID + sizeThreeOffset))")
                }
            }
        }
        stmts.append("INSERT INTO product_sizes_layouts_sets VALUES (1,1,1,1,'test.png',1)")
        stmts.append("INSERT INTO product_sizes_layouts_sets VALUES (2,2,1,1,'test.png',1)")
        stmts.append("INSERT INTO product_sizes_layouts_sets VALUES (3,3,1,1,'test.png',1)")

        for climb in climbs {
            stmts.append("INSERT INTO climbs VALUES ('\(climb.uuid)',1,1,'\(climb.setter)',"
                + "'\(climb.name)','',0,4,20,4,20,NULL,1,0,'\(climb.frames)',0,1,'\(createdAt)')")
            let best = climb.stats.max { $0.ascents < $1.ascents }!
            stmts.append("INSERT INTO climb_cache_fields VALUES "
                + "('\(climb.uuid)',\(best.ascents),\(best.diff),\(best.quality))")
            for s in climb.stats {
                stmts.append("INSERT INTO climb_stats VALUES ('\(climb.uuid)',\(s.angle),\(s.diff),"
                    + "NULL,\(s.ascents),\(s.diff),\(s.quality),'\(climb.setter)','\(createdAt)')")
            }
            let slug = climb.name.split(separator: " ").last.map(String.init)?.lowercased() ?? "x"
            stmts.append("INSERT INTO beta_links VALUES "
                + "('\(climb.uuid)','https://example.test/\(slug)',NULL,NULL,NULL,1,'\(createdAt)')")
        }
        return stmts.joined(separator: ";\n") + ";"
    }

    /// CREATE TABLE statements — the column structure the reader expects (structure, not data).
    private static let ddl: [String] = [
        """
        CREATE TABLE difficulty_grades (difficulty INT UNSIGNED NOT NULL PRIMARY KEY,
            boulder_name TEXT NOT NULL, route_name TEXT NOT NULL, is_listed BOOLEAN NOT NULL)
        """,
        """
        CREATE TABLE layouts (id INT UNSIGNED NOT NULL PRIMARY KEY, product_id INT UNSIGNED NOT NULL,
            name TEXT NOT NULL, instagram_caption TEXT NOT NULL, is_mirrored BOOLEAN NOT NULL,
            is_listed BOOLEAN NOT NULL, password TEXT NULL DEFAULT NULL, created_at TEXT NOT NULL)
        """,
        """
        CREATE TABLE holes (id INT UNSIGNED NOT NULL PRIMARY KEY, product_id INT UNSIGNED NOT NULL,
            name TEXT NOT NULL, x INT NOT NULL, y INT NOT NULL,
            mirrored_hole_id INT UNSIGNED NULL DEFAULT NULL, mirror_group INT UNSIGNED NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE placement_roles (id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_id INT UNSIGNED NOT NULL, position INT UNSIGNED NOT NULL, name TEXT NOT NULL,
            full_name TEXT NOT NULL, led_color TEXT NOT NULL, screen_color TEXT NOT NULL)
        """,
        """
        CREATE TABLE placements (id INT UNSIGNED NOT NULL PRIMARY KEY, layout_id INT UNSIGNED NOT NULL,
            hole_id INT UNSIGNED NOT NULL, hold_id INT UNSIGNED NOT NULL, rotation INT NOT NULL,
            default_placement_role_id INT UNSIGNED NULL DEFAULT NULL)
        """,
        """
        CREATE TABLE product_sizes (id INT UNSIGNED NOT NULL PRIMARY KEY, name TEXT NOT NULL,
            description TEXT)
        """,
        """
        CREATE TABLE leds (id INT UNSIGNED NOT NULL PRIMARY KEY, product_size_id INT UNSIGNED NOT NULL,
            hole_id INT UNSIGNED NOT NULL, position INT UNSIGNED NOT NULL)
        """,
        """
        CREATE TABLE product_sizes_layouts_sets (id INT UNSIGNED NOT NULL PRIMARY KEY,
            product_size_id INT UNSIGNED NOT NULL, layout_id INT UNSIGNED NOT NULL,
            set_id INT UNSIGNED NOT NULL, image_filename TEXT NOT NULL, is_listed BOOLEAN NOT NULL)
        """,
        """
        CREATE TABLE climbs (uuid TEXT NOT NULL PRIMARY KEY, layout_id INT UNSIGNED NOT NULL,
            setter_id INT UNSIGNED NOT NULL, setter_username TEXT NOT NULL, name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '', hsm INT UNSIGNED NOT NULL,
            edge_left INT UNSIGNED NOT NULL, edge_right INT UNSIGNED NOT NULL,
            edge_bottom INT UNSIGNED NOT NULL, edge_top INT UNSIGNED NOT NULL, angle INT NULL DEFAULT NULL,
            frames_count INT UNSIGNED NOT NULL DEFAULT 1, frames_pace INT UNSIGNED NOT NULL DEFAULT 0,
            frames TEXT NOT NULL, is_draft BOOLEAN NOT NULL DEFAULT 0, is_listed BOOLEAN NOT NULL,
            created_at TEXT NOT NULL)
        """,
        """
        CREATE TABLE climb_stats (climb_uuid TEXT NOT NULL, angle INT UNSIGNED NOT NULL,
            display_difficulty FLOAT UNSIGNED NOT NULL, benchmark_difficulty FLOAT UNSIGNED NULL DEFAULT NULL,
            ascensionist_count INT UNSIGNED NOT NULL, difficulty_average FLOAT UNSIGNED NOT NULL,
            quality_average FLOAT UNSIGNED NOT NULL, fa_username TEXT NOT NULL, fa_at TEXT NOT NULL,
            PRIMARY KEY (climb_uuid, angle))
        """,
        """
        CREATE TABLE climb_cache_fields (climb_uuid TEXT NOT NULL PRIMARY KEY,
            ascensionist_count INT UNSIGNED NULL DEFAULT NULL,
            display_difficulty FLOAT UNSIGNED NULL DEFAULT NULL,
            quality_average FLOAT UNSIGNED NULL DEFAULT NULL)
        """,
        """
        CREATE TABLE beta_links (climb_uuid TEXT NOT NULL, link TEXT NOT NULL,
            foreign_username TEXT NULL DEFAULT NULL, angle INT NULL DEFAULT NULL,
            thumbnail TEXT NULL DEFAULT NULL, is_listed BOOLEAN NOT NULL, created_at TEXT NOT NULL,
            PRIMARY KEY (climb_uuid, link))
        """,
    ]

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorPointer)
            throw Failure.exec(message)
        }
    }
}
