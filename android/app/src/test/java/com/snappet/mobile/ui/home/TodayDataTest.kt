package com.snappet.mobile.ui.home

import com.snappet.mobile.feature.habit.Habit
import com.snappet.mobile.feature.habit.HabitCompletion
import com.snappet.mobile.feature.habit.HabitStats
import com.snappet.mobile.feature.pomodoro.PomodoroSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TodayDataTest {

    private val now = System.currentTimeMillis()
    private val today = HabitStats.startOfDay(now)
    private val yesterday = today - 24L * 3600_000L

    @Test fun habits_doneTodayAndStreak() {
        val habits = listOf(
            Habit(habitId = "h1", name = "Stretch", createdAt = yesterday),
            Habit(habitId = "h2", name = "Read", createdAt = yesterday),
        )
        val completions = listOf(
            HabitCompletion(habitId = "h1", day = today),
            HabitCompletion(habitId = "h1", day = yesterday),  // h1 has a 2-day streak
            HabitCompletion(habitId = "h2", day = yesterday),  // h2 not done today
        )
        val r = TodayData.habits(habits, completions, now)
        assertEquals(1, r.doneToday)   // only h1
        assertEquals(2, r.total)
        assertEquals(2, r.bestStreak)  // h1's 2-day run
    }

    @Test fun isHabitDoneToday() {
        val completions = listOf(HabitCompletion(habitId = "h1", day = today))
        assertTrue(TodayData.isHabitDoneToday("h1", completions, now))
        assertFalse(TodayData.isHabitDoneToday("h2", completions, now))
    }

    @Test fun focus_minutesTodayOnly() {
        val sessions = listOf(
            PomodoroSession(minutes = 25, completedAt = today + 1000),
            PomodoroSession(minutes = 25, completedAt = today + 2000),
            PomodoroSession(minutes = 50, completedAt = yesterday),  // excluded
        )
        assertEquals(50, TodayData.focus(sessions, now).minutesToday)
    }

    @Test fun kilter_latestSession() {
        val sessions = listOf(
            com.snappet.mobile.feature.kilter.KilterSession(id = "old", startedAt = yesterday, endedAt = yesterday + 1000, angle = 40, source = "manual"),
            com.snappet.mobile.feature.kilter.KilterSession(id = "new", startedAt = today, endedAt = null, angle = 40, source = "ble"),
        )
        val r = TodayData.kilter(sessions) { id -> if (id == "new") 3 to 5 else 0 to 0 }!!
        assertTrue(r.isActive)
        assertEquals(3, r.sends)
        assertEquals(5, r.climbs)
    }
}
