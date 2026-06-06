package com.snappet.mobile.feature.kilter

import android.database.sqlite.SQLiteDatabase
import java.io.File

/** Thrown when a candidate catalog file isn't usable. [message] is user-facing. */
class KilterCatalogException(
    val reason: Reason,
    private val tables: List<String> = emptyList(),
) : Exception(reason.message(tables)) {

    enum class Reason {
        UNREADABLE, MISSING_TABLES, NO_CLIMBS, TOO_LARGE, SYNC_UNAVAILABLE;

        fun message(tables: List<String>): String = when (this) {
            UNREADABLE -> "That file isn't a readable SQLite database."
            MISSING_TABLES ->
                "That database is missing required Kilter tables (${tables.joinToString()}) — " +
                    "it doesn't look like a Kilter catalog."
            NO_CLIMBS -> "That catalog has no climbs in it."
            TOO_LARGE -> "That file is too large to be a Kilter catalog."
            SYNC_UNAVAILABLE ->
                "In-app catalog sync isn't available yet. For now, import a catalog file you built " +
                    "with the boardlib tool (see the Kilter tooling README)."
        }
    }
}

/**
 * Validates a candidate `.sqlite3` before install: it must be readable SQLite, carry the tables the
 * reader needs, and have at least one listed climb. Derives a deterministic version for the meta.
 * Mirrors the iOS `KilterCatalogValidator`. Uses Android SQLite, so it's covered by instrumented tests
 * (not JVM `src/test`).
 */
object KilterCatalogValidator {
    data class Validated(val version: String, val climbCount: Int, val sizeBytes: Long)

    val requiredTables = listOf(
        "difficulty_grades", "layouts", "climbs", "climb_stats",
        "placements", "holes", "placement_roles", "leds")
    const val MAX_BYTES = 512L * 1_000_000L

    fun validate(file: File): Validated {
        val size = file.length()
        if (size > MAX_BYTES) throw KilterCatalogException(KilterCatalogException.Reason.TOO_LARGE)

        val db = try {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY)
        } catch (_: Exception) {
            throw KilterCatalogException(KilterCatalogException.Reason.UNREADABLE)
        }
        db.use {
            val present = try {
                tableNames(it)
            } catch (_: Exception) {
                throw KilterCatalogException(KilterCatalogException.Reason.UNREADABLE)
            }
            val missing = requiredTables.filter { t -> t !in present }
            if (missing.isNotEmpty())
                throw KilterCatalogException(KilterCatalogException.Reason.MISSING_TABLES, missing)

            val climbCount = scalarInt(it, "SELECT COUNT(*) FROM climbs WHERE is_listed = 1")
            if (climbCount == 0) throw KilterCatalogException(KilterCatalogException.Reason.NO_CLIMBS)
            val statCount = scalarInt(it, "SELECT COUNT(*) FROM climb_stats")
            val gradeCount = scalarInt(it, "SELECT COUNT(*) FROM difficulty_grades")
            val marker = scalarText(it, "SELECT MAX(created_at) FROM climbs") ?: ""
            val version = "c$climbCount·s$statCount·g$gradeCount·" +
                fnv1aHex("$climbCount|$statCount|$gradeCount|$marker")
            return Validated(version, climbCount, size)
        }
    }

    private fun tableNames(db: SQLiteDatabase): Set<String> {
        val out = HashSet<String>()
        db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'", null).use { c ->
            while (c.moveToNext()) out.add(c.getString(0))
        }
        return out
    }

    private fun scalarInt(db: SQLiteDatabase, sql: String): Int =
        db.rawQuery(sql, null).use { if (it.moveToNext()) it.getInt(0) else 0 }

    private fun scalarText(db: SQLiteDatabase, sql: String): String? =
        db.rawQuery(sql, null).use { if (it.moveToNext() && !it.isNull(0)) it.getString(0) else null }

    private fun fnv1aHex(s: String): String {
        var hash = 0xcbf29ce484222325uL
        for (b in s.toByteArray()) {
            hash = hash xor b.toUByte().toULong()
            hash *= 0x100000001b3uL
        }
        return (hash and 0xffffffffuL).toString(16).padStart(8, '0')
    }
}
