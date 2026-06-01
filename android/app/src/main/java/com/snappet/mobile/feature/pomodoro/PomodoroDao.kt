package com.snappet.mobile.feature.pomodoro

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface PomodoroDao {
    @Insert
    suspend fun insert(session: PomodoroSession)

    /** All sessions, newest first — drives history + the 7-day chart. */
    @Query("SELECT * FROM pomodoro_sessions ORDER BY completedAt DESC")
    fun allFlow(): Flow<List<PomodoroSession>>
}
