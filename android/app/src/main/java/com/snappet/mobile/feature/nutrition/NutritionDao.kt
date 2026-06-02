package com.snappet.mobile.feature.nutrition

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface NutritionDao {
    @Insert
    suspend fun insertEntry(entry: FoodLogEntry): Long

    @Delete
    suspend fun deleteEntry(entry: FoodLogEntry)

    @Upsert
    suspend fun upsertGoal(goal: NutritionGoal)

    @Query("SELECT * FROM nutrition_goals WHERE id = 1")
    fun goalFlow(): Flow<NutritionGoal?>

    /** All entries logged on or after [fromMillis], newest first. */
    @Query("SELECT * FROM food_log_entries WHERE loggedAt >= :fromMillis ORDER BY loggedAt DESC")
    fun entriesSinceFlow(fromMillis: Long): Flow<List<FoodLogEntry>>

    @Insert
    suspend fun insertCustomFood(food: CustomFood): Long

    @Delete
    suspend fun deleteCustomFood(food: CustomFood)

    @Query("SELECT * FROM custom_foods ORDER BY createdAt DESC")
    fun customFoodsFlow(): Flow<List<CustomFood>>
}
