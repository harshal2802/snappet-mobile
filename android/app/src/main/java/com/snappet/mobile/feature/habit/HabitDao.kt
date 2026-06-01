package com.snappet.mobile.feature.habit

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface HabitDao {
    @Insert
    suspend fun insertHabit(habit: Habit)

    @Update
    suspend fun updateHabit(habit: Habit)

    @Delete
    suspend fun deleteHabit(habit: Habit)

    @Insert
    suspend fun insertCompletion(completion: HabitCompletion)

    @Delete
    suspend fun deleteCompletion(completion: HabitCompletion)

    @Query("DELETE FROM habit_completions WHERE habitId = :habitId")
    suspend fun deleteCompletionsFor(habitId: String)

    /** All habits, oldest first — mirrors the iOS `@Query(sort: \Habit.createdAt)`. */
    @Query("SELECT * FROM habits ORDER BY createdAt ASC")
    fun habitsFlow(): Flow<List<Habit>>

    /** All completions across every habit. */
    @Query("SELECT * FROM habit_completions")
    fun completionsFlow(): Flow<List<HabitCompletion>>
}
