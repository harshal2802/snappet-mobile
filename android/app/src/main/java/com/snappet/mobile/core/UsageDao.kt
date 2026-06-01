package com.snappet.mobile.core

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface UsageDao {
    @Insert
    suspend fun insert(record: UsageRecord)

    /** Reactive stream of all records (newest first) — drives the live Home dashboard. */
    @Query("SELECT * FROM usage_records ORDER BY timestamp DESC")
    fun allFlow(): Flow<List<UsageRecord>>

    /** Most-recent records (activity feed). */
    @Query("SELECT * FROM usage_records ORDER BY timestamp DESC LIMIT :limit")
    suspend fun recent(limit: Int = 40): List<UsageRecord>

    /** Records on/after `since` epoch millis (for day/week aggregation). */
    @Query("SELECT * FROM usage_records WHERE timestamp >= :since ORDER BY timestamp DESC")
    suspend fun since(since: Long): List<UsageRecord>
}
