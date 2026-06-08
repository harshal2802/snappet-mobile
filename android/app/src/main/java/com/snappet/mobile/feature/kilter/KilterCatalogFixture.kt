package com.snappet.mobile.feature.kilter

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.util.UUID
import kotlin.math.max

/**
 * Builds a tiny, **fully-synthetic** Kilter catalog (zero Aurora data — a couple of invented layouts,
 * a small invented hole grid, four made-up climbs) for tests and the UI-test install hook. Mirrors
 * `tools/kilter/build_test_fixture.py` and the Swift `KilterCatalogFixture`; keep the three in sync.
 *
 * Test support only — [installForTesting] runs solely under the instrumented-test hook (see
 * `MainActivity` / `TestHooks`), so a production run never builds or installs anything, and because the
 * rows are authored here no Aurora data ships in the APK.
 */
object KilterCatalogFixture {
    private val coords = intArrayOf(4, 8, 12, 16, 20)
    private const val createdAt = "2024-01-01 00:00:00"
    /** role id, name, screen colour, LED colour. `start` has a different `led_color` vs `screen_color`
     *  (mirrors real Kilter data) so tests cover the board using `led_color`, not the on-screen colour. */
    private data class FRole(val id: Int, val name: String, val screen: String, val led: String)
    private val roles = listOf(
        FRole(12, "start", "00DD00", "00FF00"), FRole(13, "middle", "00FFFF", "00FFFF"),
        FRole(14, "finish", "FF00FF", "FF00FF"), FRole(15, "foot", "FFA500", "FFA500"))
    /** Two same-dimension board sizes for layout 1: size 1 maps hole H → LED H; size 2 → H + offset. */
    private const val sizeTwoOffset = 1000
    /** A third, genuinely SMALLER board (5×3) wiring only the bottom [sizeThreeRows] rows (holes 1–15),
     *  so tests can prove the render tracks the size (16×8 / aspect 2.0 vs the full 16×16 / aspect 1.0). */
    private const val sizeThreeRows = 3
    private const val sizeThreeOffset = 2000

    private data class Stat(val angle: Int, val diff: Double, val ascents: Int, val quality: Double)
    private data class FClimb(
        val uuid: String, val name: String, val setter: String, val frames: String,
        val stats: List<Stat>, val description: String = "", val isNoMatch: Boolean = false)

    private val climbs = listOf(
        FClimb("11111111-1111-4111-8111-111111111111", "Test Problem Alpha", "fixtureSetter",
            "p1r12p13r13p25r14", listOf(Stat(40, 15.0, 250, 2.6), Stat(25, 12.0, 90, 2.1))),
        // Bravo carries the Kilter "No matching" rule (description + is_nomatch=1).
        FClimb("22222222-2222-4222-8222-222222222222", "Test Problem Bravo", "fixtureSetter",
            "p5r12p13r13p21r14", listOf(Stat(40, 20.0, 120, 2.9), Stat(30, 18.0, 60, 2.4)),
            description = "No matching", isNoMatch = true),
        FClimb("33333333-3333-4333-8333-333333333333", "Test Problem Charlie", "anotherSetter",
            "p3r12p7r13p19r13p23r14", listOf(Stat(40, 24.0, 45, 1.8))),
        FClimb("44444444-4444-4444-8444-444444444444", "Test Problem Delta", "anotherSetter",
            "p2r12p14r13p24r14", listOf(Stat(25, 10.0, 300, 3.0), Stat(40, 16.0, 200, 2.7))))

    /** Write the synthetic catalog to [file] (overwriting). Returns [file]. */
    fun build(file: File): File {
        if (file.exists()) file.delete()
        file.parentFile?.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
            db.beginTransaction()
            try {
                ddl.forEach { db.execSQL(it) }
                for (d in 1..39) db.execSQL(
                    "INSERT INTO difficulty_grades VALUES ($d,'${d}a/V${max(0, d / 3)}','route$d',1)")
                db.execSQL("INSERT INTO layouts VALUES (1,1,'Test Wall A','',0,1,NULL,'$createdAt')")
                db.execSQL("INSERT INTO layouts VALUES (2,1,'Test Wall B','',0,1,NULL,'$createdAt')")
                // placement_roles columns: id, product_id, position, name, full_name, led_color, screen_color
                for (r in roles) db.execSQL(
                    "INSERT INTO placement_roles VALUES (${r.id},1,${r.id},'${r.name}','${r.name}','${r.led}','${r.screen}')")

                // product_sizes carry a fit box (edge_*): sizes 1/2 are a tall 0..24 board (fits every
                // climb); size 3 (Mini) is short (top 12) so tall climbs don't fit it.
                db.execSQL("INSERT INTO product_sizes VALUES (1,'5 x 5','Test Small',0,24,0,24)")
                db.execSQL("INSERT INTO product_sizes VALUES (2,'5 x 5','Test Large',0,24,0,24)")
                db.execSQL("INSERT INTO product_sizes VALUES (3,'5 x 3','Test Mini',0,24,4,12)")

                var holeId = 0
                for ((row, y) in coords.withIndex()) {
                    for ((col, x) in coords.withIndex()) {
                        holeId++
                        val name = "${'A' + row}${col + 1}"
                        db.execSQL("INSERT INTO holes VALUES ($holeId,1,'$name',$x,$y,NULL,0)")
                        db.execSQL("INSERT INTO placements VALUES ($holeId,1,$holeId,$holeId,0,NULL)")
                        // Sizes 1/2 (same dimensions): hole H → position H, resp. H + offset (different address).
                        db.execSQL("INSERT INTO leds VALUES ($holeId,1,$holeId,$holeId)")
                        db.execSQL("INSERT INTO leds VALUES (${holeId + 10000},2,$holeId,${holeId + sizeTwoOffset})")
                        // Size 3 (the smaller board) wires only the bottom rows → it renders a shorter board.
                        if (row < sizeThreeRows) {
                            db.execSQL("INSERT INTO leds VALUES (${holeId + 20000},3,$holeId,${holeId + sizeThreeOffset})")
                        }
                    }
                }
                db.execSQL("INSERT INTO product_sizes_layouts_sets VALUES (1,1,1,1,'test.png',1)")
                db.execSQL("INSERT INTO product_sizes_layouts_sets VALUES (2,2,1,1,'test.png',1)")
                db.execSQL("INSERT INTO product_sizes_layouts_sets VALUES (3,3,1,1,'test.png',1)")

                for (c in climbs) {
                    db.execSQL(
                        "INSERT INTO climbs VALUES ('${c.uuid}',1,1,'${c.setter}','${c.name}','${c.description}',0," +
                            "4,20,4,20,NULL,1,0,'${c.frames}',0,1,'$createdAt',${if (c.isNoMatch) 1 else 0})")
                    val best = c.stats.maxByOrNull { it.ascents }!!
                    db.execSQL("INSERT INTO climb_cache_fields VALUES " +
                        "('${c.uuid}',${best.ascents},${best.diff},${best.quality})")
                    for (s in c.stats) db.execSQL(
                        "INSERT INTO climb_stats VALUES ('${c.uuid}',${s.angle},${s.diff},NULL," +
                            "${s.ascents},${s.diff},${s.quality},'${c.setter}','$createdAt')")
                    val slug = c.name.substringAfterLast(' ').lowercase()
                    db.execSQL("INSERT INTO beta_links VALUES " +
                        "('${c.uuid}','https://example.test/$slug',NULL,NULL,NULL,1,'$createdAt')")
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        }
        return file
    }

    /** Build the fixture and install it into the store (instrumented-test hook). */
    fun installForTesting(context: Context) {
        val store = KilterCatalogStore.get(context)
        store.clear()
        val temp = File(context.cacheDir, "kilter-fixture-${UUID.randomUUID()}.sqlite3")
        try {
            build(temp)
            val v = KilterCatalogValidator.validate(temp)
            store.install(temp, KilterCatalogMeta(
                v.version, v.climbCount, v.sizeBytes, "Test fixture", System.currentTimeMillis()))
        } finally {
            if (temp.exists()) temp.delete()
        }
        KilterCatalog.reset()
    }

    /** CREATE TABLE statements — the column structure the reader expects (structure, not data). */
    private val ddl = listOf(
        "CREATE TABLE difficulty_grades (difficulty INT UNSIGNED NOT NULL PRIMARY KEY, " +
            "boulder_name TEXT NOT NULL, route_name TEXT NOT NULL, is_listed BOOLEAN NOT NULL)",
        "CREATE TABLE layouts (id INT UNSIGNED NOT NULL PRIMARY KEY, product_id INT UNSIGNED NOT NULL, " +
            "name TEXT NOT NULL, instagram_caption TEXT NOT NULL, is_mirrored BOOLEAN NOT NULL, " +
            "is_listed BOOLEAN NOT NULL, password TEXT NULL DEFAULT NULL, created_at TEXT NOT NULL)",
        "CREATE TABLE holes (id INT UNSIGNED NOT NULL PRIMARY KEY, product_id INT UNSIGNED NOT NULL, " +
            "name TEXT NOT NULL, x INT NOT NULL, y INT NOT NULL, " +
            "mirrored_hole_id INT UNSIGNED NULL DEFAULT NULL, mirror_group INT UNSIGNED NOT NULL DEFAULT 0)",
        "CREATE TABLE placement_roles (id INT UNSIGNED NOT NULL PRIMARY KEY, " +
            "product_id INT UNSIGNED NOT NULL, position INT UNSIGNED NOT NULL, name TEXT NOT NULL, " +
            "full_name TEXT NOT NULL, led_color TEXT NOT NULL, screen_color TEXT NOT NULL)",
        "CREATE TABLE placements (id INT UNSIGNED NOT NULL PRIMARY KEY, layout_id INT UNSIGNED NOT NULL, " +
            "hole_id INT UNSIGNED NOT NULL, hold_id INT UNSIGNED NOT NULL, rotation INT NOT NULL, " +
            "default_placement_role_id INT UNSIGNED NULL DEFAULT NULL)",
        "CREATE TABLE product_sizes (id INT UNSIGNED NOT NULL PRIMARY KEY, name TEXT NOT NULL, " +
            "description TEXT, edge_left INT NOT NULL DEFAULT 0, edge_right INT NOT NULL DEFAULT 0, " +
            "edge_bottom INT NOT NULL DEFAULT 0, edge_top INT NOT NULL DEFAULT 0)",
        "CREATE TABLE leds (id INT UNSIGNED NOT NULL PRIMARY KEY, product_size_id INT UNSIGNED NOT NULL, " +
            "hole_id INT UNSIGNED NOT NULL, position INT UNSIGNED NOT NULL)",
        "CREATE TABLE product_sizes_layouts_sets (id INT UNSIGNED NOT NULL PRIMARY KEY, " +
            "product_size_id INT UNSIGNED NOT NULL, layout_id INT UNSIGNED NOT NULL, " +
            "set_id INT UNSIGNED NOT NULL, image_filename TEXT NOT NULL, is_listed BOOLEAN NOT NULL)",
        "CREATE TABLE climbs (uuid TEXT NOT NULL PRIMARY KEY, layout_id INT UNSIGNED NOT NULL, " +
            "setter_id INT UNSIGNED NOT NULL, setter_username TEXT NOT NULL, name TEXT NOT NULL, " +
            "description TEXT NOT NULL DEFAULT '', hsm INT UNSIGNED NOT NULL, " +
            "edge_left INT UNSIGNED NOT NULL, edge_right INT UNSIGNED NOT NULL, " +
            "edge_bottom INT UNSIGNED NOT NULL, edge_top INT UNSIGNED NOT NULL, angle INT NULL DEFAULT NULL, " +
            "frames_count INT UNSIGNED NOT NULL DEFAULT 1, frames_pace INT UNSIGNED NOT NULL DEFAULT 0, " +
            "frames TEXT NOT NULL, is_draft BOOLEAN NOT NULL DEFAULT 0, is_listed BOOLEAN NOT NULL, " +
            "created_at TEXT NOT NULL, is_nomatch BOOLEAN NOT NULL DEFAULT 0)",
        "CREATE TABLE climb_stats (climb_uuid TEXT NOT NULL, angle INT UNSIGNED NOT NULL, " +
            "display_difficulty FLOAT UNSIGNED NOT NULL, benchmark_difficulty FLOAT UNSIGNED NULL DEFAULT NULL, " +
            "ascensionist_count INT UNSIGNED NOT NULL, difficulty_average FLOAT UNSIGNED NOT NULL, " +
            "quality_average FLOAT UNSIGNED NOT NULL, fa_username TEXT NOT NULL, fa_at TEXT NOT NULL, " +
            "PRIMARY KEY (climb_uuid, angle))",
        "CREATE TABLE climb_cache_fields (climb_uuid TEXT NOT NULL PRIMARY KEY, " +
            "ascensionist_count INT UNSIGNED NULL DEFAULT NULL, " +
            "display_difficulty FLOAT UNSIGNED NULL DEFAULT NULL, " +
            "quality_average FLOAT UNSIGNED NULL DEFAULT NULL)",
        "CREATE TABLE beta_links (climb_uuid TEXT NOT NULL, link TEXT NOT NULL, " +
            "foreign_username TEXT NULL DEFAULT NULL, angle INT NULL DEFAULT NULL, " +
            "thumbnail TEXT NULL DEFAULT NULL, is_listed BOOLEAN NOT NULL, created_at TEXT NOT NULL, " +
            "PRIMARY KEY (climb_uuid, link))")
}
