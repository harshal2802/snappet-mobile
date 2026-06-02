package com.snappet.mobile.feature.kilter

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

/** How a logged attempt resolved. Stored by [name] on [KilterLogEntry]. Mirrors iOS `KilterAscentStatus`. */
enum class KilterAscentStatus(val label: String) {
    FLASH("Flash"), SENT("Sent"), PROJECT("Project"), ATTEMPT("Attempt");

    /** Counts toward "sends" in the history pyramid. */
    val isSend: Boolean get() = this == SENT || this == FLASH

    companion object {
        fun from(raw: String): KilterAscentStatus = entries.firstOrNull { it.name == raw } ?: ATTEMPT
    }
}

/**
 * One logged attempt on a climb at a given angle. Persisted in the shared SnappetCore store (separate
 * from the read-only catalog). Snapshots `climbName`/`gradeLabel` so History renders without
 * re-opening the catalog. Optionally tagged with the `sessionId` of the board session it was logged
 * in. Mirrors the iOS `KilterLogEntry` `@Model`.
 */
@Entity(tableName = "kilter_log")
data class KilterLogEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val climbUuid: String,
    val climbName: String,
    val angle: Int,
    /** Float difficulty at the logged angle (for the grade pyramid / sorting). */
    val difficulty: Double,
    val gradeLabel: String,
    /** [KilterAscentStatus.name]. */
    val status: String,
    val attempts: Int = 1,
    /** Epoch millis; newest-first sorting. */
    val createdAt: Long,
    /** [KilterSession.id] when captured during a connected board session; null for ad-hoc logs. */
    val sessionId: String? = null,
)

/**
 * A board session — opened when a board connects over BLE (or started manually), grouping the
 * [KilterLogEntry]s logged while active so History can show sessions. Mirrors iOS `KilterSession`.
 */
@Entity(tableName = "kilter_session")
data class KilterSession(
    @PrimaryKey val id: String,
    val startedAt: Long,
    val endedAt: Long? = null,
    val angle: Int,
    /** `"ble"` when auto-captured from a connected board, `"manual"` otherwise. */
    val source: String,
)

/** A climb the user starred. Its own table so the "Saved" filter is a fast membership check. */
@Entity(tableName = "kilter_favorite")
data class KilterFavorite(
    @PrimaryKey val climbUuid: String,
    val addedAt: Long,
)

@Dao
interface KilterDao {
    @Insert suspend fun insertLog(entry: KilterLogEntry)

    @Query("SELECT * FROM kilter_log ORDER BY createdAt DESC")
    fun logsFlow(): Flow<List<KilterLogEntry>>

    @Query("DELETE FROM kilter_log") suspend fun clearLogs()

    @Insert suspend fun insertSession(session: KilterSession)

    @Query("UPDATE kilter_session SET endedAt = :endedAt WHERE id = :id")
    suspend fun endSession(id: String, endedAt: Long)

    @Query("SELECT * FROM kilter_session ORDER BY startedAt DESC")
    fun sessionsFlow(): Flow<List<KilterSession>>

    @Query("DELETE FROM kilter_session") suspend fun clearSessions()

    @Query("SELECT * FROM kilter_favorite ORDER BY addedAt DESC")
    fun favoritesFlow(): Flow<List<KilterFavorite>>

    @Insert suspend fun addFavorite(favorite: KilterFavorite)
    @Delete suspend fun removeFavorite(favorite: KilterFavorite)
}
