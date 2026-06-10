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
            sqlite.beginTransaction()
            try {
                for (table in userTables(sqlite)) {
                    sqlite.execSQL("DELETE FROM `$table`")
                    val incoming = payload.tables[table] ?: continue
                    tables += 1
                    for (row in incoming) {
                        sqlite.insert(table, android.database.sqlite.SQLiteDatabase.CONFLICT_ABORT,
                                      contentValues(row))
                        rows += 1
                    }
                }
                // Auto-increment counters follow the restored rows, not the wiped past.
                // (`sqlite_sequence` only exists if some column ever used AUTOINCREMENT —
                // Room's plain `INTEGER PRIMARY KEY` doesn't — so probe before touching it.)
                val hasSequence = sqlite.query(
                    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'"
                ).use { it.moveToFirst() }
                if (hasSequence) sqlite.execSQL("DELETE FROM sqlite_sequence")
                sqlite.setTransactionSuccessful()
            } finally {
                sqlite.endTransaction()
            }
            Summary(tables, rows)
        }

    companion object {
        /** Every table that holds user data — i.e. everything but SQLite/Room bookkeeping. */
        fun userTables(sqlite: SupportSQLiteDatabase): List<String> {
            val names = ArrayList<String>()
            sqlite.query(
                "SELECT name FROM sqlite_master WHERE type = 'table' " +
                    "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' " +
                    "AND name NOT LIKE 'room_%' ORDER BY name"
            ).use { cursor ->
                while (cursor.moveToNext()) names.add(cursor.getString(0))
            }
            return names
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
