package com.snappet.mobile.feature.habit

import java.util.Calendar
import java.util.concurrent.TimeUnit

/**
 * Pure date math + streak / completion-rate calculations, ported 1:1 from the iOS
 * `HabitRootView` helpers (`streak(for:)`, `completionRate(for:)`). Kept framework-free so it is
 * deterministic and easy to reason about.
 */
object HabitStats {
    private val dayMs = TimeUnit.DAYS.toMillis(1)

    /** Normalise an epoch-millis timestamp to local start-of-day. Mirrors `Calendar.startOfDay`. */
    fun startOfDay(ts: Long): Long {
        val cal = Calendar.getInstance().apply {
            timeInMillis = ts
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return cal.timeInMillis
    }

    /** start-of-day for `today - offset` days. */
    fun dayBefore(start: Long, days: Int): Long = startOfDay(start - days * dayMs)

    /**
     * Current streak = consecutive calendar days completed, ending today. If today isn't done
     * yet we still count a streak ending *yesterday*, so a streak stays alive until a full day is
     * missed. Ported from iOS `streak(for:)`.
     */
    fun streak(completionDays: Set<Long>, now: Long = System.currentTimeMillis()): Int {
        if (completionDays.isEmpty()) return 0
        val today = startOfDay(now)
        var cursor = if (completionDays.contains(today)) today else dayBefore(today, 1)
        if (!completionDays.contains(cursor)) return 0
        var count = 0
        while (completionDays.contains(cursor)) {
            count += 1
            cursor = dayBefore(cursor, 1)
        }
        return count
    }

    /**
     * 30-day completion rate: completions in the trailing window ÷ window, where the window is the
     * inclusive days since creation capped at 30 (min 1). Ported from iOS `completionRate(for:)`.
     */
    fun completionRate(completionDays: Set<Long>, createdAt: Long, now: Long = System.currentTimeMillis()): Double {
        val today = startOfDay(now)
        val createdDay = startOfDay(createdAt)
        val elapsed = ((today - createdDay) / dayMs).toInt() + 1
        val window = elapsed.coerceIn(1, 30)
        val windowStart = dayBefore(today, window - 1)
        val done = completionDays.count { it in windowStart..today }
        return done.toDouble() / window.toDouble()
    }
}

/** One day in a habit's 7-day strip. [offset] is days before today (0 == today). */
data class WeekDay(val offset: Int, val dayStart: Long, val isDone: Boolean)
