package com.snappet.mobile.ui.home

import com.snappet.mobile.feature.habit.Habit
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.habit.HabitStats
import com.snappet.mobile.feature.kilter.KilterSession
import com.snappet.mobile.feature.pomodoro.PomodoroSession
import java.util.concurrent.TimeUnit

/**
 * Pure aggregation of the cross-module "Today" snapshot (issue #99). Both the in-app Home cards and
 * the Glance launcher widgets feed the same Room flow values through this, so the two never drift.
 * No Android / Compose deps → JVM-unit-tested. Mirrors the iOS `TodayDigest` intent.
 */
object TodayData {

    /** Habits done today vs total, plus the best current streak across all habits. */
    data class HabitsToday(val doneToday: Int, val total: Int, val bestStreak: Int)

    /** Focus minutes logged today. */
    data class FocusToday(val minutesToday: Int)

    /** The latest Kilter session (active or last), with its send/climb counts. */
    data class KilterToday(val isActive: Boolean, val sends: Int, val climbs: Int)

    fun habits(
        habits: List<Habit>,
        completions: List<HabitCompletion>,
        now: Long = System.currentTimeMillis(),
    ): HabitsToday {
        val today = HabitStats.startOfDay(now)
        val doneToday = habits.count { h ->
            completions.any { it.habitId == h.habitId && it.day == today }
        }
        val bestStreak = habits.maxOfOrNull { h ->
            val days = completions.filter { it.habitId == h.habitId }.map { it.day }.toSet()
            HabitStats.streak(days, now)
        } ?: 0
        return HabitsToday(doneToday = doneToday, total = habits.size, bestStreak = bestStreak)
    }

    fun focus(sessions: List<PomodoroSession>, now: Long = System.currentTimeMillis()): FocusToday {
        val dayStart = HabitStats.startOfDay(now)
        val minutes = sessions.filter { it.completedAt >= dayStart }.sumOf { it.minutes }
        return FocusToday(minutesToday = minutes)
    }

    fun kilter(
        sessions: List<KilterSession>,
        sendCountFor: (sessionId: String) -> Pair<Int, Int>,
    ): KilterToday? {
        val latest = sessions.maxByOrNull { it.startedAt } ?: return null
        val (sends, climbs) = sendCountFor(latest.id)
        return KilterToday(isActive = latest.endedAt == null, sends = sends, climbs = climbs)
    }

    /** True if the habit is completed on the local day containing [now]. */
    fun isHabitDoneToday(
        habitId: String,
        completions: List<HabitCompletion>,
        now: Long = System.currentTimeMillis(),
    ): Boolean {
        val today = HabitStats.startOfDay(now)
        return completions.any { it.habitId == habitId && it.day == today }
    }

    private val dayMs = TimeUnit.DAYS.toMillis(1)
}
