package com.snappet.mobile.feature.habit

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * A habit the user wants to do every day. Keyed by a stable [habitId] (UUID string) so
 * [HabitCompletion] records can reference it independently of the Room row id. Mirrors the iOS
 * `Habit` `@Model`.
 */
@Entity(tableName = "habits")
data class Habit(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Stable identity used to key [HabitCompletion] records. */
    val habitId: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    /** Icon key shown on the row (one of [HabitSymbols.all]). */
    val symbol: String = HabitSymbols.default,
    /** When the habit was created (epoch millis). */
    val createdAt: Long,
)

/**
 * One "done" mark for a habit on a single calendar day. [day] is normalised to the start of the
 * day (via [HabitStats.startOfDay]) so there is at most one completion per habit per day and day
 * comparisons are exact. Mirrors the iOS `HabitCompletion` `@Model`.
 */
@Entity(tableName = "habit_completions")
data class HabitCompletion(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Matches [Habit.habitId]. */
    val habitId: String,
    /** Start-of-day for the day this habit was completed (epoch millis). */
    val day: Long,
)
