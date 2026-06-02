package com.snappet.mobile.feature.kilter

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File
import kotlin.math.roundToInt

// MARK: catalog value types (read-only, from the bundled kilter.sqlite3)

data class KilterListItem(
    val uuid: String,
    val name: String,
    val setter: String,
    val difficulty: Double,
    val gradeLabel: String,
    val quality: Double,
    val ascents: Int,
)

data class KilterClimb(
    val uuid: String,
    val name: String,
    val setter: String,
    val layoutId: Int,
    val edgeLeft: Int,
    val edgeRight: Int,
    val edgeBottom: Int,
    val edgeTop: Int,
    val frames: String,
)

data class KilterClimbStat(
    val angle: Int,
    val difficulty: Double,
    val benchmarkDifficulty: Double?,
    val ascents: Int,
    val quality: Double,
    val faUsername: String,
)

/** One lit hold, normalized to view space (x,y in 0..1, y from the top), colored by role. */
data class KilterHold(
    val placementId: Int,
    val x: Double,
    val y: Double,
    val colorHex: String,
    val role: String,
    val ledPosition: Int?,
)

data class KilterLayout(val id: Int, val name: String)

/** One hole position normalized to view space (x,y in 0..1, y from the top) — the faint board grid. */
data class KilterGridHole(val x: Double, val y: Double)

/** A board layout's drawable geometry: aspect ratio + the full normalized hole grid. */
data class KilterBoardGeometry(val aspect: Double, val grid: List<KilterGridHole>) {
    companion object { val EMPTY = KilterBoardGeometry(1.0, emptyList()) }
}

/** How grades render (the catalog ships combined "6a/V3" labels). Mirrors iOS `KilterGradeFormat`. */
enum class KilterGradeFormat(val label: String) {
    BOTH("Font / V"), V("V-scale"), FONT("Font");

    companion object { fun from(raw: String?) = entries.firstOrNull { it.name == raw } ?: BOTH }
}

/** Reformat a combined "6a/V3" grade label per the user's preference. */
fun kilterDisplayGrade(label: String, format: KilterGradeFormat): String {
    val parts = label.split('/', limit = 2)
    if (parts.size != 2) return label
    return when (format) {
        KilterGradeFormat.BOTH -> label
        KilterGradeFormat.FONT -> parts[0]
        KilterGradeFormat.V -> parts[1]
    }
}

/** How a climb's catalog list is ordered. Mirrors iOS `KilterSort`. */
enum class KilterSort(val label: String, val orderBy: String) {
    POPULAR("Most climbed", "cs.ascensionist_count DESC"),
    HARDEST("Hardest", "cs.display_difficulty DESC, cs.ascensionist_count DESC"),
    EASIEST("Easiest", "cs.display_difficulty ASC, cs.ascensionist_count DESC"),
    QUALITY("Highest quality", "cs.quality_average DESC, cs.ascensionist_count DESC"),
}

/** The full set of catalog browse criteria (search + filters + sort). Mirrors iOS `KilterFilter`. */
data class KilterFilter(
    val layoutId: Int,
    val angle: Int,
    val minDifficulty: Double,
    val maxDifficulty: Double,
    val search: String = "",
    val sort: KilterSort = KilterSort.POPULAR,
    val benchmarksOnly: Boolean = false,
    val minAscents: Int = 0,
    val minQuality: Double = 0.0,
) {
    /** Count of optional (beyond layout/angle/grade) filters active — for a badge. */
    val activeExtras: Int
        get() = (if (benchmarksOnly) 1 else 0) + (if (minAscents > 0) 1 else 0) +
            (if (minQuality > 0) 1 else 0) + (if (sort != KilterSort.POPULAR) 1 else 0)
}

/**
 * Read-only access layer over the bundled `kilter.sqlite3` catalog (built by
 * `tools/kilter/build_bundled_db.py`). This is static reference data — copied out of `assets/` once,
 * opened read-only, never written, and kept out of Room (which owns user data). On-device only: no
 * network. A missing/corrupt asset degrades to an empty catalog ([isAvailable] = false) rather than
 * crashing the suite. Mirrors the iOS `KilterCatalog`.
 */
class KilterCatalog private constructor(private val db: SQLiteDatabase?) {

    val isAvailable: Boolean get() = db != null && grades.isNotEmpty()

    private val grades = HashMap<Int, String>()
    private val roleScreenColor = HashMap<Int, String>()
    private val placementXY = HashMap<Int, Pair<Int, Int>>()
    private val placementHole = HashMap<Int, Int>()
    private val ledCache = HashMap<Int, Map<Int, Int>>()
    private val extentCache = HashMap<Int, IntArray>()   // layoutId -> [minX,maxX,minY,maxY]
    private val geometryCache = HashMap<Int, KilterBoardGeometry>()

    init {
        if (db != null) loadReference()
    }

    private fun loadReference() {
        db ?: return
        db.rawQuery("SELECT difficulty, boulder_name FROM difficulty_grades", null).use { c ->
            while (c.moveToNext()) grades[c.getInt(0)] = c.getString(1)
        }
        db.rawQuery("SELECT id, screen_color FROM placement_roles", null).use { c ->
            while (c.moveToNext()) roleScreenColor[c.getInt(0)] = c.getString(1)
        }
        db.rawQuery("SELECT p.id, h.x, h.y, p.hole_id FROM placements p JOIN holes h ON h.id = p.hole_id", null).use { c ->
            while (c.moveToNext()) {
                placementXY[c.getInt(0)] = c.getInt(1) to c.getInt(2)
                placementHole[c.getInt(0)] = c.getInt(3)
            }
        }
    }

    fun layouts(): List<KilterLayout> {
        val db = db ?: return emptyList()
        val out = ArrayList<KilterLayout>()
        db.rawQuery(
            "SELECT l.id, l.name FROM layouts l WHERE l.id IN " +
                "(SELECT DISTINCT layout_id FROM climbs WHERE is_listed = 1) ORDER BY l.id", null
        ).use { c -> while (c.moveToNext()) out.add(KilterLayout(c.getInt(0), c.getString(1))) }
        return out
    }

    fun angles(): List<Int> {
        val db = db ?: return emptyList()
        val out = ArrayList<Int>()
        db.rawQuery("SELECT DISTINCT angle FROM climb_stats ORDER BY angle", null).use { c ->
            while (c.moveToNext()) out.add(c.getInt(0))
        }
        return out
    }

    fun list(layoutId: Int, angle: Int, minDifficulty: Double, maxDifficulty: Double, limit: Int = 500): List<KilterListItem> {
        val db = db ?: return emptyList()
        val out = ArrayList<KilterListItem>()
        db.rawQuery(
            """
            SELECT c.uuid, c.name, c.setter_username, cs.display_difficulty,
                   cs.quality_average, cs.ascensionist_count
            FROM climbs c
            JOIN climb_stats cs ON cs.climb_uuid = c.uuid AND cs.angle = ?
            WHERE c.is_listed = 1 AND c.layout_id = ?
              AND cs.display_difficulty BETWEEN ? AND ?
            ORDER BY cs.ascensionist_count DESC
            LIMIT ?
            """.trimIndent(),
            arrayOf(angle.toString(), layoutId.toString(), minDifficulty.toString(), maxDifficulty.toString(), limit.toString())
        ).use { c ->
            while (c.moveToNext()) {
                val diff = c.getDouble(3)
                out.add(KilterListItem(c.getString(0), c.getString(1), c.getString(2),
                    diff, gradeLabel(diff), c.getDouble(4), c.getInt(5)))
            }
        }
        return out
    }

    fun climbsByUuid(uuids: List<String>): List<KilterListItem> {
        val db = db ?: return emptyList()
        if (uuids.isEmpty()) return emptyList()
        val out = ArrayList<KilterListItem>()
        for (uuid in uuids) {
            db.rawQuery(
                """
                SELECT c.uuid, c.name, c.setter_username, cf.display_difficulty,
                       cf.quality_average, cf.ascensionist_count
                FROM climbs c
                LEFT JOIN climb_cache_fields cf ON cf.climb_uuid = c.uuid
                WHERE c.uuid = ?
                """.trimIndent(), arrayOf(uuid)
            ).use { c ->
                if (c.moveToNext()) {
                    val diff = c.getDouble(3)
                    out.add(KilterListItem(c.getString(0), c.getString(1), c.getString(2),
                        diff, gradeLabel(diff), c.getDouble(4), c.getInt(5)))
                }
            }
        }
        return out
    }

    fun climb(uuid: String): KilterClimb? {
        val db = db ?: return null
        db.rawQuery(
            "SELECT uuid, name, setter_username, layout_id, edge_left, edge_right, edge_bottom, edge_top, frames " +
                "FROM climbs WHERE uuid = ?", arrayOf(uuid)
        ).use { c ->
            if (!c.moveToNext()) return null
            return KilterClimb(c.getString(0), c.getString(1), c.getString(2), c.getInt(3),
                c.getInt(4), c.getInt(5), c.getInt(6), c.getInt(7), c.getString(8))
        }
    }

    fun stats(uuid: String): List<KilterClimbStat> {
        val db = db ?: return emptyList()
        val out = ArrayList<KilterClimbStat>()
        db.rawQuery(
            "SELECT angle, display_difficulty, benchmark_difficulty, ascensionist_count, quality_average, fa_username " +
                "FROM climb_stats WHERE climb_uuid = ? ORDER BY angle", arrayOf(uuid)
        ).use { c ->
            while (c.moveToNext()) {
                out.add(KilterClimbStat(c.getInt(0), c.getDouble(1),
                    if (c.isNull(2)) null else c.getDouble(2), c.getInt(3), c.getDouble(4), c.getString(5)))
            }
        }
        return out
    }

    fun betaLinks(uuid: String): List<String> {
        val db = db ?: return emptyList()
        val out = ArrayList<String>()
        db.rawQuery("SELECT link FROM beta_links WHERE climb_uuid = ? AND is_listed = 1", arrayOf(uuid)).use { c ->
            while (c.moveToNext()) out.add(c.getString(0))
        }
        return out
    }

    /**
     * Decode a climb's `frames` into positioned, colored holds. Normalized against the **whole board's**
     * hole extent for the layout (not the climb's own edges), so every climb renders at the same scale
     * and lines up with the faint grid from [boardGeometry]. Mirrors iOS.
     */
    fun holds(climb: KilterClimb): List<KilterHold> {
        val e = extent(climb.layoutId)
        val w = (e[1] - e[0]).toDouble()
        val h = (e[3] - e[2]).toDouble()
        if (w <= 0 || h <= 0) return emptyList()
        val leds = ledPositions(climb.layoutId)
        val out = ArrayList<KilterHold>()
        for ((placementId, roleId) in parseFrames(climb.frames)) {
            val xy = placementXY[placementId] ?: continue
            val nx = (xy.first - e[0]) / w
            val ny = (xy.second - e[2]) / h
            out.add(KilterHold(
                placementId = placementId,
                x = nx.coerceIn(0.0, 1.0),
                y = 1 - ny.coerceIn(0.0, 1.0),   // board y is bottom-up; view y is top-down
                colorHex = roleScreenColor[roleId] ?: "FFFFFF",
                role = roleName(roleId),
                ledPosition = placementHole[placementId]?.let { leds[it] }))
        }
        return out
    }

    fun gradeLabel(difficulty: Double): String = grades[difficulty.roundToInt()] ?: "—"

    fun gradeScale(): List<Pair<Int, String>> = grades.keys.sorted().map { it to grades.getValue(it) }

    /** `[minX,maxX,minY,maxY]` board-coordinate extent of every placement on a layout. */
    private fun extent(layoutId: Int): IntArray {
        extentCache[layoutId]?.let { return it }
        val db = db ?: return intArrayOf(0, 1, 0, 1)
        var e = intArrayOf(0, 1, 0, 1)
        db.rawQuery(
            "SELECT MIN(h.x), MAX(h.x), MIN(h.y), MAX(h.y) FROM placements p " +
                "JOIN holes h ON h.id = p.hole_id WHERE p.layout_id = ?", arrayOf(layoutId.toString())
        ).use { c -> if (c.moveToNext() && !c.isNull(0)) e = intArrayOf(c.getInt(0), c.getInt(1), c.getInt(2), c.getInt(3)) }
        extentCache[layoutId] = e
        return e
    }

    /** The board's drawable geometry: aspect ratio + the full normalized hole grid (deduped by hole). */
    fun boardGeometry(layoutId: Int): KilterBoardGeometry {
        geometryCache[layoutId]?.let { return it }
        val db = db ?: return KilterBoardGeometry.EMPTY
        val e = extent(layoutId)
        val w = (e[1] - e[0]).toDouble(); val h = (e[3] - e[2]).toDouble()
        if (w <= 0 || h <= 0) return KilterBoardGeometry.EMPTY
        val grid = ArrayList<KilterGridHole>()
        val seen = HashSet<Int>()
        db.rawQuery(
            "SELECT DISTINCT p.hole_id, h.x, h.y FROM placements p " +
                "JOIN holes h ON h.id = p.hole_id WHERE p.layout_id = ?", arrayOf(layoutId.toString())
        ).use { c ->
            while (c.moveToNext()) {
                if (!seen.add(c.getInt(0))) continue
                val nx = (c.getInt(1) - e[0]) / w
                val ny = (c.getInt(2) - e[2]) / h
                grid.add(KilterGridHole(nx, 1 - ny))
            }
        }
        return KilterBoardGeometry(w / h, grid).also { geometryCache[layoutId] = it }
    }

    /** Catalog list driven by the full [KilterFilter] (search/sort/benchmark/min ascents+quality). */
    fun list(f: KilterFilter, limit: Int = 500): List<KilterListItem> {
        val db = db ?: return emptyList()
        val lo = minOf(f.minDifficulty, f.maxDifficulty)
        val hi = maxOf(f.minDifficulty, f.maxDifficulty)
        val term = f.search.trim()
        val args = ArrayList<String>()
        val sql = StringBuilder(
            """
            SELECT c.uuid, c.name, c.setter_username, cs.display_difficulty,
                   cs.quality_average, cs.ascensionist_count
            FROM climbs c
            JOIN climb_stats cs ON cs.climb_uuid = c.uuid AND cs.angle = ?
            WHERE c.is_listed = 1 AND c.layout_id = ?
              AND cs.display_difficulty BETWEEN ? AND ?
              AND cs.ascensionist_count >= ? AND cs.quality_average >= ?
            """.trimIndent()
        )
        args.add(f.angle.toString()); args.add(f.layoutId.toString())
        args.add(lo.toString()); args.add(hi.toString())
        args.add(f.minAscents.toString()); args.add(f.minQuality.toString())
        if (term.isNotEmpty()) {
            sql.append(" AND (c.name LIKE ? OR c.setter_username LIKE ?)")
            args.add("%$term%"); args.add("%$term%")
        }
        if (f.benchmarksOnly) sql.append(" AND cs.benchmark_difficulty IS NOT NULL")
        sql.append(" ORDER BY ").append(f.sort.orderBy).append(" LIMIT ?")  // enum-controlled clause
        args.add(limit.toString())

        val out = ArrayList<KilterListItem>()
        db.rawQuery(sql.toString(), args.toTypedArray()).use { c ->
            while (c.moveToNext()) {
                val diff = c.getDouble(3)
                out.add(KilterListItem(c.getString(0), c.getString(1), c.getString(2),
                    diff, gradeLabel(diff), c.getDouble(4), c.getInt(5)))
            }
        }
        return out
    }

    /** A random climb matching the current filter (Discovery "Surprise me"). */
    fun randomClimb(f: KilterFilter): KilterListItem? = list(f, limit = 500).randomOrNull()

    /** A deterministic "climb of the day" — a popular classic for the layout/angle, rotating daily. */
    fun climbOfTheDay(layoutId: Int, angle: Int): KilterListItem? {
        var pool = list(KilterFilter(layoutId, angle, 1.0, 39.0, sort = KilterSort.POPULAR, benchmarksOnly = true), 150)
        if (pool.isEmpty()) pool = list(KilterFilter(layoutId, angle, 1.0, 39.0, sort = KilterSort.POPULAR), 150)
        if (pool.isEmpty()) return null
        val day = (System.currentTimeMillis() / 86_400_000L).toInt()
        return pool[(day % pool.size + pool.size) % pool.size]
    }

    private fun ledPositions(layoutId: Int): Map<Int, Int> {
        ledCache[layoutId]?.let { return it }
        val db = db ?: return emptyMap()
        var sizeId = 0
        db.rawQuery("SELECT MIN(product_size_id) FROM product_sizes_layouts_sets WHERE layout_id = ?",
            arrayOf(layoutId.toString())).use { c -> if (c.moveToNext()) sizeId = c.getInt(0) }
        val map = HashMap<Int, Int>()
        db.rawQuery("SELECT hole_id, position FROM leds WHERE product_size_id = ?",
            arrayOf(sizeId.toString())).use { c -> while (c.moveToNext()) map[c.getInt(0)] = c.getInt(1) }
        ledCache[layoutId] = map
        return map
    }

    companion object {
        private const val ASSET = "kilter.sqlite3"
        @Volatile private var instance: KilterCatalog? = null

        /** Shared catalog, copying the asset out on first use. Safe to call from any thread. */
        fun get(context: Context): KilterCatalog =
            instance ?: synchronized(this) { instance ?: open(context).also { instance = it } }

        private fun open(context: Context): KilterCatalog {
            return try {
                val dest = File(context.filesDir, ASSET)
                if (!dest.exists() || dest.length() == 0L) {
                    context.assets.open(ASSET).use { input -> dest.outputStream().use { input.copyTo(it) } }
                }
                KilterCatalog(SQLiteDatabase.openDatabase(dest.path, null, SQLiteDatabase.OPEN_READONLY))
            } catch (_: Exception) {
                KilterCatalog(null)
            }
        }

        /** Parse `p<placement>r<role>` tokens into `(placementId, roleId)` pairs. */
        fun parseFrames(frames: String): List<Pair<Int, Int>> {
            val out = ArrayList<Pair<Int, Int>>()
            for (token in frames.split('p')) {
                if (token.isEmpty()) continue
                val parts = token.split('r')
                if (parts.size != 2) continue
                val p = parts[0].toIntOrNull() ?: continue
                val r = parts[1].toIntOrNull() ?: continue
                out.add(p to r)
            }
            return out
        }

        private fun roleName(roleId: Int): String = when (roleId) {
            12, 42 -> "start"
            13, 43 -> "middle"
            14, 44 -> "finish"
            15, 45 -> "foot"
            else -> "hold"
        }
    }
}
