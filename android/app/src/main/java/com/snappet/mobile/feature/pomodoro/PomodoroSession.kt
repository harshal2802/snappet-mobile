package com.snappet.mobile.feature.pomodoro

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * One completed focus block. Inserted into the shared store whenever a FOCUS phase runs to
 * completion. Mirrors the iOS `PomodoroSession` `@Model`.
 */
@Entity(tableName = "pomodoro_sessions")
data class PomodoroSession(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Length of the completed focus block, in minutes. */
    val minutes: Int,
    /** When the focus block finished (epoch millis). */
    val completedAt: Long,
)
