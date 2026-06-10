package com.snappet.mobile.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull

/**
 * The Snappet backup payload codec (issue #84): one versioned JSON document holding every
 * row of every user table, **schema-agnostically** — rows are column→value maps read at
 * the SQLite level, so new entities are covered automatically and the format can't drift
 * from the schema. Values carry SQLite's own storage classes (INTEGER/REAL/TEXT/BLOB/
 * NULL); BLOBs ride as `{"__blob": base64}` (none exist today, but the format won't
 * corrupt one). Pure encode/decode/validate → unit-tested on the JVM.
 *
 * Import compatibility is strict: a payload only restores into the **same Room schema
 * version** it was exported from. Cross-version restore is the migration pipeline's job —
 * open the old DB, let Room migrate, re-export.
 */
object SnappetBackup {

    const val FORMAT_VERSION = 1
    private const val BLOB_KEY = "__blob"

    /** One decoded backup: provenance + every table's rows. */
    data class Payload(
        val formatVersion: Int,
        val dbVersion: Int,
        val exportedAtMillis: Long,
        /** table name → rows; each row is column name → (Long | Double | String | ByteArray | null). */
        val tables: Map<String, List<Map<String, Any?>>>,
    )

    fun encode(payload: Payload): String {
        val root = buildJsonObject {
            put("formatVersion", JsonPrimitive(payload.formatVersion))
            put("dbVersion", JsonPrimitive(payload.dbVersion))
            put("exportedAtMillis", JsonPrimitive(payload.exportedAtMillis))
            put("tables", buildJsonObject {
                for ((table, rows) in payload.tables) {
                    put(table, buildJsonArray {
                        for (row in rows) {
                            add(buildJsonObject {
                                for ((column, value) in row) {
                                    put(column, encodeCell(value))
                                }
                            })
                        }
                    })
                }
            })
        }
        return Json.encodeToString(JsonObject.serializer(), root)
    }

    /** @throws IllegalArgumentException when the document isn't a Snappet backup this app can read. */
    fun decode(text: String): Payload {
        val root = runCatching { Json.parseToJsonElement(text).jsonObject }
            .getOrElse { throw IllegalArgumentException("Not a Snappet backup file.") }
        val format = root["formatVersion"]?.jsonPrimitive?.int
            ?: throw IllegalArgumentException("Not a Snappet backup file.")
        require(format == FORMAT_VERSION) {
            "This backup uses format $format; this app reads format $FORMAT_VERSION."
        }
        val dbVersion = root["dbVersion"]?.jsonPrimitive?.int
            ?: throw IllegalArgumentException("Backup is missing its schema version.")
        val exportedAt = root["exportedAtMillis"]?.jsonPrimitive?.long ?: 0L
        val tablesJson = root["tables"]?.jsonObject
            ?: throw IllegalArgumentException("Backup contains no data tables.")

        val tables = LinkedHashMap<String, List<Map<String, Any?>>>()
        for ((table, rowsElement) in tablesJson) {
            val rows = (rowsElement as? JsonArray)
                ?: throw IllegalArgumentException("Table \"$table\" is malformed.")
            tables[table] = rows.map { rowElement ->
                val obj = (rowElement as? JsonObject)
                    ?: throw IllegalArgumentException("Table \"$table\" has a malformed row.")
                obj.mapValues { (_, cell) -> decodeCell(cell) }
            }
        }
        return Payload(format, dbVersion, exportedAt, tables)
    }

    /** A human-readable reason this payload can't be imported here, or `null` when it can. */
    fun validate(payload: Payload, currentDbVersion: Int): String? = when {
        payload.formatVersion != FORMAT_VERSION ->
            "This backup uses an unsupported format."
        payload.dbVersion != currentDbVersion ->
            "This backup was made by a ${if (payload.dbVersion < currentDbVersion) "older" else "newer"} " +
                "version of Snappet (schema v${payload.dbVersion}, this app is v$currentDbVersion). " +
                if (payload.dbVersion < currentDbVersion)
                    "Open it once in the version that wrote it, update, and export again."
                else "Update Snappet, then import."
        payload.tables.isEmpty() -> "The backup contains no data."
        else -> null
    }

    private fun encodeCell(value: Any?) = when (value) {
        null -> JsonNull
        is Long -> JsonPrimitive(value)
        is Double -> JsonPrimitive(value)
        is String -> JsonPrimitive(value)
        is ByteArray -> buildJsonObject { put(BLOB_KEY, JsonPrimitive(base64Encode(value))) }
        else -> throw IllegalArgumentException("Unsupported cell type: ${value::class}")
    }

    private fun decodeCell(cell: kotlinx.serialization.json.JsonElement): Any? = when (cell) {
        is JsonNull -> null
        is JsonObject -> base64Decode(
            cell[BLOB_KEY]?.jsonPrimitive?.content
                ?: throw IllegalArgumentException("Malformed blob cell."))
        is JsonPrimitive -> when {
            cell.isString -> cell.content
            else -> cell.longOrNull ?: cell.doubleOrNull
                ?: throw IllegalArgumentException("Malformed numeric cell.")
        }
        else -> throw IllegalArgumentException("Malformed cell.")
    }

    // java.util.Base64 works on API 26+ and the JVM unit-test classpath alike.
    private fun base64Encode(bytes: ByteArray): String =
        java.util.Base64.getEncoder().encodeToString(bytes)

    private fun base64Decode(text: String): ByteArray =
        java.util.Base64.getDecoder().decode(text)
}
