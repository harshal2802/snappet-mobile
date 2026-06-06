package com.snappet.mobile.feature.kilter

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Metadata sidecar for one installed catalog (issue #42) — lets Settings show version/size/count/name
 * without reopening SQLite. Serialized as `catalog.meta.json` with `org.json`. Mirrors iOS
 * `KilterCatalogMeta`. `name` is optional so older single-catalog sidecars still decode.
 */
data class KilterCatalogMeta(
    val version: String,
    val climbCount: Int,
    val sizeBytes: Long,
    val source: String,
    val installedAtMillis: Long,
    val name: String? = null,
) {
    fun toJson(): String = JSONObject().apply {
        put("version", version)
        put("climbCount", climbCount)
        put("sizeBytes", sizeBytes)
        put("source", source)
        put("installedAtMillis", installedAtMillis)
        name?.let { put("name", it) }
    }.toString()

    companion object {
        fun fromJson(text: String): KilterCatalogMeta? = try {
            val o = JSONObject(text)
            KilterCatalogMeta(
                o.getString("version"), o.getInt("climbCount"), o.getLong("sizeBytes"),
                o.optString("source", "Imported file"), o.optLong("installedAtMillis", 0L),
                if (o.has("name")) o.getString("name") else null)
        } catch (_: Exception) {
            null
        }
    }
}

/** One installed catalog in the on-device library. */
data class InstalledCatalog(val id: String, val meta: KilterCatalogMeta, val file: File) {
    val displayName: String get() = meta.name ?: meta.source
}

/**
 * Owns the on-device, **user-installed** Kilter catalog **library** (`filesDir/kilter/catalogs/<id>/
 * catalog.sqlite3` + `catalog.meta.json`), plus which one is **active** (the one the read-only
 * [KilterCatalog] opens), tracked in `filesDir/kilter/active-catalog`.
 *
 * The app ships **no** catalog (issue #42 — we don't redistribute Aurora Climbing's data). The user
 * installs one or more themselves (file import or the hosted download), keeps several, switches the
 * active one, and removes any individually. Mirrors the iOS `KilterCatalogStore`.
 */
class KilterCatalogStore(private val dir: File) {
    private val catalogsDir = File(dir, "catalogs")
    private val activeFile = File(dir, "active-catalog")
    private val legacyDB = File(dir, "kilter.sqlite3")
    private val legacyMeta = File(dir, "catalog.meta.json")

    init { migrateLegacyIfNeeded() }

    private fun activeId(): String? =
        if (activeFile.exists()) activeFile.readText().trim().ifEmpty { null } else null

    private fun dbFile(id: String) = File(File(catalogsDir, id), "catalog.sqlite3")
    private fun metaFile(id: String) = File(File(catalogsDir, id), "catalog.meta.json")

    /** The active catalog's `.sqlite3` (what the reader opens); a non-existent path when none active. */
    val catalogFile: File get() = activeId()?.let { dbFile(it) } ?: File(catalogsDir, "none/catalog.sqlite3")

    val isInstalled: Boolean get() = activeId()?.let { dbFile(it).let { f -> f.exists() && f.length() > 0L } } ?: false
    val activeCatalogId: String? get() = if (isInstalled) activeId() else null

    fun metadata(): KilterCatalogMeta? = activeId()?.let { readMeta(it) }

    /** Every installed catalog, most-recently-installed first. */
    fun installed(): List<InstalledCatalog> {
        val dirs = catalogsDir.listFiles()?.filter { it.isDirectory } ?: return emptyList()
        return dirs.mapNotNull { d ->
            val db = File(d, "catalog.sqlite3")
            val meta = readMeta(d.name)
            if (db.exists() && db.length() > 0L && meta != null) InstalledCatalog(d.name, meta, db) else null
        }.sortedByDescending { it.meta.installedAtMillis }
    }

    /** Copy a validated catalog into a **new** library entry and make it active. Caller deletes [src]. */
    fun install(src: File, meta: KilterCatalogMeta): String {
        val id = UUID.randomUUID().toString()
        File(catalogsDir, id).mkdirs()
        src.copyTo(dbFile(id), overwrite = true)
        metaFile(id).writeText(meta.toJson())
        setActive(id)
        return id
    }

    /** Remove one catalog. If it was active, promote the most-recent remaining (or none). */
    fun remove(id: String) {
        File(catalogsDir, id).deleteRecursively()
        if (activeId() == id) {
            val next = installed().firstOrNull()
            if (next != null) setActive(next.id) else activeFile.delete()
        }
    }

    /** Make [id] the catalog the reader opens. */
    fun setActive(id: String) {
        if (dbFile(id).exists()) activeFile.writeText(id)
    }

    /** Remove the entire library (Settings "remove all" / tests / fixture reset). */
    fun clear(): Boolean {
        val had = isInstalled
        catalogsDir.deleteRecursively()
        activeFile.delete()
        legacyDB.delete(); legacyMeta.delete()
        return had
    }

    private fun readMeta(id: String): KilterCatalogMeta? {
        val f = metaFile(id)
        return if (f.exists()) KilterCatalogMeta.fromJson(f.readText()) else null
    }

    /** One-time: fold a pre-multi-catalog single install into the library so it survives the upgrade. */
    private fun migrateLegacyIfNeeded() {
        if (!legacyDB.exists()) return
        val id = UUID.randomUUID().toString()
        try {
            File(catalogsDir, id).mkdirs()
            legacyDB.copyTo(dbFile(id), overwrite = true)
            legacyDB.delete()
            if (legacyMeta.exists()) {
                legacyMeta.copyTo(metaFile(id), overwrite = true); legacyMeta.delete()
            } else {
                metaFile(id).writeText(KilterCatalogMeta(
                    "migrated", 0, dbFile(id).length(), "Imported file",
                    System.currentTimeMillis(), "Imported catalog").toJson())
            }
            setActive(id)
        } catch (_: Exception) {
            // Leave the legacy file alone on failure rather than lose it.
        }
    }

    companion object {
        @Volatile private var instance: KilterCatalogStore? = null

        fun get(context: Context): KilterCatalogStore =
            instance ?: synchronized(this) {
                instance ?: KilterCatalogStore(File(context.filesDir, "kilter")).also { instance = it }
            }
    }
}
