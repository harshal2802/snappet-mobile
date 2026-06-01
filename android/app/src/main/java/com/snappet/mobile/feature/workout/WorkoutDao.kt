package com.snappet.mobile.feature.workout

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.Update
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

/**
 * Room DAO for the Workout Tracker store: routines, sessions, and custom exercises. Suspend
 * mutators + `Flow` queries collected with `collectAsState`. Mirrors the iOS `@Query` ordering
 * (routines by recency, sessions by start time). Imported by the flagship Workout integrator.
 */
@Dao
interface WorkoutDao {

    // Routines ---------------------------------------------------------------

    @Insert
    suspend fun insertRoutine(routine: WorkoutRoutine)

    @Update
    suspend fun updateRoutine(routine: WorkoutRoutine)

    @Delete
    suspend fun deleteRoutine(routine: WorkoutRoutine)

    /** All routines, most-recently-updated first. */
    @Query("SELECT * FROM workout_routines ORDER BY updatedAt DESC")
    fun routinesFlow(): Flow<List<WorkoutRoutine>>

    /** One-shot fetch used by the starter seed to decide what's already present. */
    @Query("SELECT * FROM workout_routines")
    suspend fun allRoutines(): List<WorkoutRoutine>

    // Sessions ---------------------------------------------------------------

    @Insert
    suspend fun insertSession(session: WorkoutSession): Long

    @Update
    suspend fun updateSession(session: WorkoutSession)

    @Delete
    suspend fun deleteSession(session: WorkoutSession)

    /** All sessions, newest first — drives history + dashboard stats. */
    @Query("SELECT * FROM workout_sessions ORDER BY startedAt DESC")
    fun sessionsFlow(): Flow<List<WorkoutSession>>

    // Custom exercises -------------------------------------------------------

    @Insert
    suspend fun insertCustomExercise(exercise: WorkoutCustomExercise)

    @Delete
    suspend fun deleteCustomExercise(exercise: WorkoutCustomExercise)

    @Query("SELECT * FROM workout_custom_exercises ORDER BY createdAt DESC")
    fun customExercisesFlow(): Flow<List<WorkoutCustomExercise>>
}
