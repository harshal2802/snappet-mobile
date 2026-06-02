package com.snappet.mobile.feature.nutrition

import androidx.room.Entity
import androidx.room.PrimaryKey

enum class MealSlot { BREAKFAST, LUNCH, DINNER, SNACK }

/** A single food entry logged by the user. Mirrors iOS `FoodLogEntry` `@Model`. */
@Entity(tableName = "food_log_entries")
data class FoodLogEntry(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val foodId: String,
    val foodName: String,
    val brandName: String = "",
    val dataSource: String = "seed",
    val mealSlot: String = MealSlot.BREAKFAST.name,
    val servingGrams: Double = 100.0,
    val kcalPer100g: Double,
    val proteinPer100g: Double,
    val carbsPer100g: Double,
    val fatPer100g: Double,
    val loggedAt: Long = System.currentTimeMillis(),
)

/** A user-defined food item stored locally. Mirrors iOS `CustomFood` `@Model`. */
@Entity(tableName = "custom_foods")
data class CustomFood(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val brandName: String = "",
    val kcalPer100g: Double,
    val proteinPer100g: Double,
    val carbsPer100g: Double,
    val fatPer100g: Double,
    val createdAt: Long = System.currentTimeMillis(),
)

/** Singleton row (id = 1) for the user's daily macro targets. Mirrors iOS `NutritionGoal` `@Model`. */
@Entity(tableName = "nutrition_goals")
data class NutritionGoal(
    @PrimaryKey val id: Int = 1,
    val dailyKcal: Int = 2000,
    val proteinG: Int = 150,
    val carbsG: Int = 200,
    val fatG: Int = 65,
)
