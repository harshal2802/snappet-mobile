package com.snappet.mobile.feature.kilter

import android.database.sqlite.SQLiteDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.zip.GZIPInputStream

/**
 * **Phase 2 — in-app catalog download from a hosted dataset.** Fetches a board's catalog as a gzipped
 * SQLite from a static host the user controls (the Snappet Board Explorer GitHub Pages site by default),
 * then trims it on-device to the chosen filters — mirroring the explorer's `exportDb.ts` — and hands
 * back a small importable file for [installKilterCatalog]. Mirrors the iOS `HostedCatalogClient`.
 *
 * Legal posture (issue #42): the dataset is **user-hosted** and the app just downloads a file from a URL
 * the user controls. No Aurora API calls, no accounts, nothing uploaded; one GET to the configured host.
 * Personal/sideload only.
 */

/** Default host for the gzipped board datasets + `manifest.json` (the Board Explorer's `board-data/`). */
const val KILTER_DEFAULT_CATALOG_HOST = "https://harshal2802.github.io/Snappet/board-data/"

/** One board in the host's `manifest.json`. Only `importableToMobile` boards are offered. */
data class CatalogBoardEntry(
    val board: String,
    val label: String,
    val file: String,
    val url: String?,
    val climbs: Int,
    val importableToMobile: Boolean,
)

/**
 * The subset filter applied on-device after download. Mirrors the Board Explorer's `FilterState`
 * (`query.ts buildConditions`) + a `maxClimbs` top-N cap (0 = no cap). Defaults are the explorer's
 * "mobile-compatible" mode: listed + single-frame + Kilter layouts.
 */
data class CatalogFilter(
    val layoutIds: List<Int> = listOf(1, 8),   // empty = all layouts
    /** A `product_size`: keep only climbs that physically fit that board size (climb `edge_*` box ⊆
     *  [sizeBox]). [sizeId] is the picker selection; [sizeBox] its resolved `product_sizes.edge_*` box. */
    val sizeId: Int? = null,
    val sizeBox: KilterSizeBox? = null,
    val angle: Int? = null,
    val gradeMin: Int? = null,
    val gradeMax: Int? = null,
    val minAscents: Int? = null,
    val minQuality: Double? = null,
    val setter: String = "",
    val name: String = "",
    val benchmarkOnly: Boolean = false,
    val listedOnly: Boolean = true,
    val singleFrameOnly: Boolean = true,
    val maxClimbs: Int = 2000,
)

class HostedCatalogClient(baseURL: String = KILTER_DEFAULT_CATALOG_HOST) {
    private val base = if (baseURL.endsWith("/")) baseURL else "$baseURL/"

    /** Reference/geometry tables copied WHOLE (mirrors Board Explorer `schema.ts` FULL_TABLES). */
    private val fullTables = listOf(
        "difficulty_grades", "products", "product_sizes", "layouts", "sets",
        "product_sizes_layouts_sets", "products_angles", "placement_roles", "holes", "holds",
        "placements", "leds")
    /** Climb tables, subset by the filtered uuids → climb-key column. */
    private val climbTables = listOf(
        "climbs" to "uuid", "climb_stats" to "climb_uuid",
        "climb_cache_fields" to "climb_uuid", "beta_links" to "climb_uuid")

    /** Importable boards from the host manifest; falls back to a lone Kilter entry. */
    suspend fun importableBoards(): List<CatalogBoardEntry> = withContext(Dispatchers.IO) {
        val fallback = listOf(CatalogBoardEntry("kilter", "Kilter Board", "kilter.sqlite.gz", null, 0, true))
        try {
            val text = (URL(base + "manifest.json").openConnection() as HttpURLConnection).run {
                connectTimeout = 15000; readTimeout = 15000
                inputStream.bufferedReader().use { it.readText() }
            }
            val arr = JSONObject(text).getJSONArray("boards")
            val out = ArrayList<CatalogBoardEntry>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                if (!o.optBoolean("importableToMobile", false)) continue
                out.add(CatalogBoardEntry(
                    o.getString("board"), o.optString("label", o.getString("board")),
                    o.getString("file"), if (o.has("url")) o.getString("url") else null,
                    o.optInt("climbs", 0), true))
            }
            if (out.isEmpty()) fallback else out
        } catch (_: Exception) {
            fallback
        }
    }

    /** Download → gunzip → filter → return a small catalog file for the installer, using [cacheDir] for
     *  the (large, transient) download + decompressed source. */
    suspend fun buildCatalog(
        cacheDir: File,
        board: CatalogBoardEntry,
        filter: CatalogFilter,
        onProgress: (Float) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        if (!board.importableToMobile) throw KilterCatalogException(KilterCatalogException.Reason.NOT_IMPORTABLE)
        val gz = File(cacheDir, "kilter-dl-${UUID.randomUUID()}.sqlite.gz")
        val raw = File(cacheDir, "kilter-raw-${UUID.randomUUID()}.sqlite3")
        try {
            download(board.url ?: board.file, gz) { onProgress(it * 0.75f) }
            onProgress(0.78f)
            gunzip(gz, raw)
            onProgress(0.85f)
            val out = File(cacheDir, "kilter-catalog-${UUID.randomUUID()}.sqlite3")
            buildFilteredCatalog(raw.path, filter, out.path)
            onProgress(1f)
            out
        } finally {
            gz.delete(); raw.delete()
        }
    }

    // MARK: download + gunzip

    private fun download(path: String, dest: File, onProgress: (Float) -> Unit) {
        val url = if (path.startsWith("http")) URL(path) else URL(base + path)
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 20000
        conn.readTimeout = 60000
        conn.instanceFollowRedirects = true
        try {
            val code = conn.responseCode
            if (code !in 200..299) throw KilterCatalogException(KilterCatalogException.Reason.DOWNLOAD_FAILED)
            val total = conn.contentLengthLong
            var received = 0L
            conn.inputStream.use { input ->
                dest.outputStream().use { output ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        received += n
                        if (total > 0) onProgress((received.toDouble() / total).toFloat().coerceAtMost(1f))
                    }
                }
            }
            if (received <= 0L) throw KilterCatalogException(KilterCatalogException.Reason.DOWNLOAD_FAILED)
        } finally {
            conn.disconnect()
        }
    }

    private fun gunzip(src: File, dst: File) {
        try {
            GZIPInputStream(src.inputStream().buffered()).use { input ->
                dst.outputStream().use { input.copyTo(it, 1 shl 16) }
            }
        } catch (_: Exception) {
            throw KilterCatalogException(KilterCatalogException.Reason.BAD_GZIP)
        }
    }

    // MARK: filtered build (mirrors Board Explorer exportDb.ts)

    fun buildFilteredCatalog(sourcePath: String, filter: CatalogFilter, outPath: String) {
        File(outPath).delete()
        val db = SQLiteDatabase.openOrCreateDatabase(outPath, null)
        try {
            db.execSQL("ATTACH DATABASE ? AS src", arrayOf<Any?>(sourcePath))

            val fullPresent = fullTables.filter { tableExists(db, "src", it) }
            val climbPresent = climbTables.filter { tableExists(db, "src", it.first) }

            // 1. Recreate every table's schema from the source DDL.
            for (t in fullPresent + climbPresent.map { it.first }) {
                val ddl = scalarText(db, "SELECT sql FROM src.sqlite_master WHERE type='table' AND name=?", arrayOf(t))
                    ?: continue
                db.execSQL(ddl)
            }

            // 2. Copy reference/geometry tables whole.
            db.beginTransaction()
            try {
                for (t in fullPresent) db.execSQL("INSERT INTO \"$t\" SELECT * FROM src.\"$t\"")
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }

            // 3. Resolve the filtered, capped uuid set.
            db.execSQL("CREATE TEMP TABLE _keep (uuid TEXT PRIMARY KEY)")
            val (where, args) = conditions(filter)
            var uuidSql = "INSERT OR IGNORE INTO _keep(uuid) SELECT c.uuid FROM src.climbs c " +
                "JOIN src.climb_stats cs ON cs.climb_uuid = c.uuid WHERE $where " +
                "GROUP BY c.uuid ORDER BY MAX(cs.ascensionist_count) DESC"
            if (filter.maxClimbs > 0) uuidSql += " LIMIT ${filter.maxClimbs}"
            db.execSQL(uuidSql, args.toTypedArray())

            if (scalarInt(db, "SELECT COUNT(*) FROM _keep") == 0)
                throw KilterCatalogException(KilterCatalogException.Reason.NO_MATCH)

            // 4. Subset the climb tables against _keep.
            db.beginTransaction()
            try {
                for ((t, key) in climbPresent) {
                    db.execSQL("INSERT INTO \"$t\" SELECT \"$t\".* FROM src.\"$t\" AS \"$t\" " +
                        "JOIN _keep k ON k.uuid = \"$t\".\"$key\"")
                }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }

            // 5. Recreate indexes for the copied tables (best-effort).
            val kept = (fullPresent + climbPresent.map { it.first }).toSet()
            db.rawQuery("SELECT sql, tbl_name FROM src.sqlite_master WHERE type='index' AND sql IS NOT NULL", null).use { c ->
                while (c.moveToNext()) {
                    val sql = c.getString(0); val tbl = c.getString(1)
                    if (tbl in kept && !sql.isNullOrEmpty()) try { db.execSQL(sql) } catch (_: Exception) {}
                }
            }

            db.execSQL("DROP TABLE _keep")
            db.execSQL("DETACH DATABASE src")
            db.execSQL("VACUUM")
        } finally {
            db.close()
        }
    }

    /** WHERE clause + bind args mirroring Board Explorer `query.ts buildConditions`. */
    private fun conditions(f: CatalogFilter): Pair<String, List<Any>> {
        val conds = ArrayList<String>()
        val args = ArrayList<Any>()
        if (f.listedOnly) conds.add("c.is_listed = 1")
        if (f.singleFrameOnly) conds.add("c.frames_count = 1")
        if (f.layoutIds.isNotEmpty()) conds.add("c.layout_id IN (${f.layoutIds.joinToString(",")})")
        // Board size: keep only climbs whose bounding box fits inside the size's box (mirrors the Board
        // Explorer's buildConditions). Bound in [left, right, bottom, top] order.
        f.sizeBox?.let {
            conds.add("c.edge_left >= ? AND c.edge_right <= ? AND c.edge_bottom >= ? AND c.edge_top <= ?")
            args.addAll(it.params)
        }
        f.angle?.let { conds.add("cs.angle = ?"); args.add(it) }
        f.gradeMin?.let { conds.add("ROUND(cs.display_difficulty) >= ?"); args.add(it) }
        f.gradeMax?.let { conds.add("ROUND(cs.display_difficulty) <= ?"); args.add(it) }
        f.minAscents?.let { conds.add("cs.ascensionist_count >= ?"); args.add(it) }
        f.minQuality?.let { conds.add("cs.quality_average >= ?"); args.add(it) }
        f.setter.trim().takeIf { it.isNotEmpty() }?.let { conds.add("c.setter_username LIKE ?"); args.add("%$it%") }
        f.name.trim().takeIf { it.isNotEmpty() }?.let { conds.add("c.name LIKE ?"); args.add("%$it%") }
        if (f.benchmarkOnly) conds.add("cs.benchmark_difficulty IS NOT NULL")
        return (if (conds.isEmpty()) "1=1" else conds.joinToString(" AND ")) to args
    }

    private fun tableExists(db: SQLiteDatabase, schema: String, table: String): Boolean =
        scalarInt(db, "SELECT COUNT(*) FROM $schema.sqlite_master WHERE type='table' AND name=?", arrayOf(table)) > 0

    private fun scalarInt(db: SQLiteDatabase, sql: String, args: Array<String>? = null): Int =
        db.rawQuery(sql, args).use { if (it.moveToNext()) it.getInt(0) else 0 }

    private fun scalarText(db: SQLiteDatabase, sql: String, args: Array<String>? = null): String? =
        db.rawQuery(sql, args).use { if (it.moveToNext() && !it.isNull(0)) it.getString(0) else null }
}
