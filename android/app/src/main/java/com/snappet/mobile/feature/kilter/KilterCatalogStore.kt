package com.snappet.mobile.feature.kilter

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * Metadata sidecar for the installed catalog (issue #42) — lets Settings show version/size/count
 * without reopening SQLite. Serialized as `catalog.meta.json` with `org.json` (no extra dependency).
 * Mirrors the iOS `KilterCatalogMeta`.
 */
data class KilterCatalogMeta(
    val version: String,
    val climbCount: Int,
    val sizeBytes: Long,
    val source: String,
    val installedAtMillis: Long,
) {
    fun toJson(): String = JSONObject().apply {
        put("version", version)
        put("climbCount", climbCount)
        put("sizeBytes", sizeBytes)
        put("source", source)
        put("installedAtMillis", installedAtMillis)
    }.toString()

    companion object {
        fun fromJson(text: String): KilterCatalogMeta? = try {
            val o = JSONObject(text)
            KilterCatalogMeta(
                o.getString("version"), o.getInt("climbCount"), o.getLong("sizeBytes"),
                o.optString("source", "Imported file"), o.optLong("installedAtMillis", 0L))
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Owns the on-device, **user-installed** Kilter catalog file (`filesDir/kilter/kilter.sqlite3`) and a
 * `catalog.meta.json` sidecar. The app ships **no** catalog (issue #42 — we don't redistribute Aurora
 * Climbing's data). The user imports one via Storage Access Framework (`KilterCatalogProvider`) and the
 * read-only [KilterCatalog] opens it from [catalogFile]. When nothing is installed the module shows the
 * opt-in [KilterCatalogSyncScreen]. Mirrors the iOS `KilterCatalogStore`.
 */
class KilterCatalogStore(private val dir: File) {
    val catalogFile = File(dir, "kilter.sqlite3")
    private val metaFile = File(dir, "catalog.meta.json")

    val isInstalled: Boolean get() = catalogFile.exists() && catalogFile.length() > 0L

    fun metadata(): KilterCatalogMeta? =
        if (metaFile.exists()) KilterCatalogMeta.fromJson(metaFile.readText()) else null

    /** Copy a validated catalog into place (replacing any existing) + write meta. Caller deletes [src]. */
    fun install(src: File, meta: KilterCatalogMeta) {
        dir.mkdirs()
        val tmp = File(dir, "kilter.sqlite3.tmp")
        src.copyTo(tmp, overwrite = true)
        if (catalogFile.exists()) catalogFile.delete()
        if (!tmp.renameTo(catalogFile)) {
            tmp.copyTo(catalogFile, overwrite = true)
            tmp.delete()
        }
        metaFile.writeText(meta.toJson())
    }

    /** Remove the installed catalog + meta ("Remove downloaded catalog"). Returns true if one existed. */
    fun clear(): Boolean {
        val had = catalogFile.exists()
        catalogFile.delete()
        metaFile.delete()
        return had
    }

    companion object {
        @Volatile private var instance: KilterCatalogStore? = null

        fun get(context: Context): KilterCatalogStore =
            instance ?: synchronized(this) {
                instance ?: KilterCatalogStore(File(context.filesDir, "kilter")).also { instance = it }
            }
    }
}
