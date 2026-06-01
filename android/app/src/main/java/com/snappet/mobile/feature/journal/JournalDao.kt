package com.snappet.mobile.feature.journal

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.Update
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface JournalDao {
    @Insert
    suspend fun insert(entry: JournalEntry): Long

    @Update
    suspend fun update(entry: JournalEntry)

    @Delete
    suspend fun delete(entry: JournalEntry)

    /** All entries, newest first — drives the list + search. */
    @Query("SELECT * FROM journal_entries ORDER BY createdAt DESC")
    fun allFlow(): Flow<List<JournalEntry>>
}
