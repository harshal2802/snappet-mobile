package com.snappet.mobile.core

import android.content.ContentValues
import android.database.Cursor
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Reads/writes [SnappetBackup] payloads against the live Room database at the SQLite
 * level (issue #84). Export walks every user table with `SELECT *`; import replaces all
 * rows transactionally — all-or-nothing, so a malformed file can never leave the store
 * half-restored. Schema-agnostic on purpose: a new `@Entity` is covered with zero
 * changes here.
 */
class SnappetBackupManager(private val db: SnappetDatabase) {

    data class Summary(val tables: Int, val rows: Int)

    /** Snapshot every user table. */
    suspend fun exportPayload(nowMillis: Long = System.currentTimeMillis()): SnappetBackup.Payload =
        withContext(Dispatchers.IO) {
            val sqlite = db.openHelper.readableDatabase
            val tables = LinkedHashMap<String, List<Map<String, Any?>>>()
            for (table in userTables(sqlite)) {
                tables[table] = readRows(sqlite, table)
            }
            SnappetBackup.Payload(
                formatVersion = SnappetBackup.FORMAT_VERSION,
                dbVersion = sqlite.version,
                exportedAtMillis = nowMillis,
                tables = tables,
            )
        }

    /**
     * Replace the store's contents with the payload's. Validates first (see
     * [SnappetBackup.validate]); throws [IllegalArgumentException] with a user-readable
     * message when the payload can't be imported. Tables in the payload that no longer
     * exist are skipped; tables that exist but aren't in the payload are emptied — the
     * result is the exported state, not a merge.
     */
    suspend fun importPayload(payload: SnappetBackup.Payload): Summary =
        withContext(Dispatchers.IO) {
            val sqlite = db.openHelper.writableDatabase
            SnappetBackup.validate(payload, sqlite.version)?.let {
                throw IllegalArgumentException(it)
            }
            var rows = 0
            var tables = 0
            // Through Room's transaction wrapper (not raw begin/endTransaction) so the
            // InvalidationTracker refreshes afterwards — every module screen observes
            // DAO Flows, which would otherwise keep rendering pre-import data (review fix).
            // Tables are deleted in one pass and inserted in a second; no @Entity declares
            // foreign keys today, and if one ever does, wipe-all-then-insert-all stays
            // safe regardless of alphabetical table order.
            db.runInTransaction {
                val userTables = userTables(sqlite)
                for (table in userTables) sqlite.execSQL("DELETE FROM `$table`")
                for (table in userTables) {
                    val incoming = payload.tables[table] ?: continue
                    tables += 1
                    for (row in incoming) {
                        sqlite.insert(table, android.database.sqlite.SQLiteDatabase.CONFLICT_ABORT,
                                      contentValues(row))
                        rows += 1
                    }
                }
                // Auto-increment counters follow the restored rows, not the wiped past.
                // (Room's @PrimaryKey(autoGenerate = true) emits AUTOINCREMENT, so
                // `sqlite_sequence` exists on any real store — but probe anyway so a
                // schema with no auto-ids can't make this throw.)
                val hasSequence = sqlite.query(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'"
                ).use { it.moveToFirst() }
                if (hasSequence) sqlite.execSQL("DELETE FROM sqlite_sequence")
            }
            Summary(tables, rows)
        }

    companion object {
        /** Every table that holds user data — i.e. everything but SQLite/Room bookkeeping. */
        fun userTables(sqlite: SupportSQLiteDatabase): List<String> {
            val names = ArrayList<String>()
            sqlite.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .use { cursor ->
                    while (cursor.moveToNext()) names.add(cursor.getString(0))
                }
            // Filter in Kotlin, where startsWith is literal — in SQL LIKE, '_' is a
            // single-character wildcard, so `NOT LIKE 'room_%'` would also silently drop
            // a future user table named e.g. "rooms" from every backup (review fix).
            return names.filterNot { name ->
                name.startsWith("sqlite_") || name == "android_metadata" ||
                    name == "room_master_table" || name.startsWith("room_")
            }
        }

        private fun readRows(sqlite: SupportSQLiteDatabase, table: String): List<Map<String, Any?>> {
            val rows = ArrayList<Map<String, Any?>>()
            sqlite.query("SELECT * FROM `$table`").use { cursor ->
                while (cursor.moveToNext()) {
                    val row = LinkedHashMap<String, Any?>(cursor.columnCount)
                    for (i in 0 until cursor.columnCount) {
                        row[cursor.getColumnName(i)] = when (cursor.getType(i)) {
                            Cursor.FIELD_TYPE_NULL -> null
                            Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                            Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(i)
                            Cursor.FIELD_TYPE_BLOB -> cursor.getBlob(i)
                            else -> cursor.getString(i)
                        }
                    }
                    rows.add(row)
                }
            }
            return rows
        }

        private fun contentValues(row: Map<String, Any?>): ContentValues {
            val values = ContentValues(row.size)
            for ((column, value) in row) {
                when (value) {
                    null -> values.putNull(column)
                    is Long -> values.put(column, value)
                    is Double -> values.put(column, value)
                    is String -> values.put(column, value)
                    is ByteArray -> values.put(column, value)
                    else -> throw IllegalArgumentException("Unsupported cell type for $column")
                }
            }
            return values
        }
    }
}
