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
    // ── HR enrichment (issue #92, schema v4→v5). All NULLABLE so the bump is a pure additive
    //    AutoMigration (no SQL, no data touched). Populated when a BLE heart-rate strap is captured
    //    during the session; null for sessions logged without a strap or before this version.
    //    NOTE FOR REVIEWER: Wave 2 also bumps to v5 (workout columns) in a separate worktree — at
    //    merge time renumber ONE migration to v5→v6. This column-set is self-contained.
    /** Average bpm over the session, when an HR strap was captured. */
    val avgHr: Int? = null,
    /** Peak bpm over the session, when an HR strap was captured. */
    val maxHr: Int? = null,
    /** Number of HR samples captured (0/null when no strap). */
    val hrSampleCount: Int? = null,
)

/** A climb the user starred. Its own table so the "Saved" filter is a fast membership check. */
@Entity(tableName = "kilter_favorite")
data class KilterFavorite(
    @PrimaryKey val climbUuid: String,
    val addedAt: Long,
)

/**
 * A climb the user authored on this device — manually (hold-by-hold) or via the on-device generator.
 * Keyed by the deterministic content uuid ([KilterClimbIdentity]) so the same climb authored twice (even
 * on another device) collapses to one row. [asClimb] adapts it to the read-only [KilterClimb] so it flows
 * through the normal render / detail / BLE / logging path. Mirrors iOS `KilterCreatedClimb`. Surfaced via
 * the browse list's "Mine" filter.
 */
@Entity(tableName = "kilter_created")
data class KilterCreatedClimb(
    @PrimaryKey val uuid: String,
    val name: String,
    /** The author's display name (the [KilterClimb.setter] for this climb). */
    val setterUsername: String,
    val layoutId: Int,
    /** The `product_size_id` the climb was authored against (the board it fits + its LED basis). */
    val sizeId: Int,
    /** The angle the user designed for (created climbs have no per-angle catalog stats). */
    val angle: Int,
    /** `p<placement>r<role>` hold encoding (canonical/sorted). */
    val frames: String,
    val edgeLeft: Int,
    val edgeRight: Int,
    val edgeBottom: Int,
    val edgeTop: Int,
    val isNoMatch: Boolean = false,
    /** The generator's predicted grade, or the user's pick; null when unknown. */
    val predictedGrade: Double? = null,
    /** `"manual"` or `"generated"`. */
    val source: String = "manual",
    /** The generator model id when generated (provenance), else null. */
    val modelId: String? = null,
    val createdAt: Long,
) {
    /** Adapt to the read-only catalog value type so created climbs reuse the whole render/detail/BLE path. */
    fun asClimb(): KilterClimb = KilterClimb(
        uuid = uuid, name = name, setter = setterUsername, layoutId = layoutId,
        edgeLeft = edgeLeft, edgeRight = edgeRight, edgeBottom = edgeBottom, edgeTop = edgeTop,
        frames = frames, description = "", isNoMatch = isNoMatch,
    )
}

@Dao
interface KilterDao {
    @Insert suspend fun insertLog(entry: KilterLogEntry)

    @Query("SELECT * FROM kilter_log ORDER BY createdAt DESC")
    fun logsFlow(): Flow<List<KilterLogEntry>>

    /** Issue #88: a fat-fingered Flash is correctable — single-row delete + status fix. */
    @Delete suspend fun deleteLog(entry: KilterLogEntry)

    @Query("UPDATE kilter_log SET status = :status WHERE id = :id")
    suspend fun updateLogStatus(id: Long, status: String)

    @Query("DELETE FROM kilter_log") suspend fun clearLogs()

    @Insert suspend fun insertSession(session: KilterSession)

    @Query("UPDATE kilter_session SET endedAt = :endedAt WHERE id = :id")
    suspend fun endSession(id: String, endedAt: Long)

    /** Issue #92: persist the captured HR summary onto the session on end (additive v5 columns). */
    @Query("UPDATE kilter_session SET avgHr = :avgHr, maxHr = :maxHr, hrSampleCount = :count WHERE id = :id")
    suspend fun setSessionHr(id: String, avgHr: Int?, maxHr: Int?, count: Int?)

    /** Issue #92: retroactively group an existing ad-hoc log into a session (e.g. first-log-of-day
     *  auto-session adopts logs that landed before the session opened). */
    @Query("UPDATE kilter_log SET sessionId = :sessionId WHERE id = :logId")
    suspend fun setLogSession(logId: Long, sessionId: String)

    @Query("SELECT * FROM kilter_session ORDER BY startedAt DESC")
    fun sessionsFlow(): Flow<List<KilterSession>>

    @Query("DELETE FROM kilter_session") suspend fun clearSessions()

    @Query("SELECT * FROM kilter_favorite ORDER BY addedAt DESC")
    fun favoritesFlow(): Flow<List<KilterFavorite>>

    @Insert suspend fun addFavorite(favorite: KilterFavorite)
    @Delete suspend fun removeFavorite(favorite: KilterFavorite)

    // Authored climbs (manual editor / generator).
    @androidx.room.Upsert suspend fun upsertCreated(climb: KilterCreatedClimb)

    @Query("SELECT * FROM kilter_created ORDER BY createdAt DESC")
    fun createdFlow(): Flow<List<KilterCreatedClimb>>

    @Query("SELECT * FROM kilter_created")
    suspend fun allCreated(): List<KilterCreatedClimb>

    @Query("SELECT * FROM kilter_created WHERE uuid = :uuid LIMIT 1")
    suspend fun createdByUuid(uuid: String): KilterCreatedClimb?
}
