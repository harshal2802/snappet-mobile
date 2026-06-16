package com.snappet.mobile.feature.workout

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * DST tests for the dashboard day-streak (review fix). `currentStreak` used to step its cursor back
 * by a fixed 24h, which lands at the wrong wall-clock day across a 23h/25h DST boundary and breaks
 * the `days.contains(cursor)` membership test. The fix steps back one *calendar* day via
 * `WorkoutAnalytics.addDays`. These pin the US-Eastern spring-forward (2021-03-14, a 23h day).
 */
class WorkoutStreakTest {

    private var savedTz: TimeZone? = null

    private fun useEastern() {
        savedTz = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"))
    }

    @After fun restoreTz() {
        savedTz?.let { TimeZone.setDefault(it) }
        savedTz = null
    }

    private fun noon(year: Int, month0: Int, day: Int): Long {
        val cal = Calendar.getInstance()
        cal.clear()
        cal.set(year, month0, day, 12, 0, 0)
        return cal.timeInMillis
    }

    private fun session(startedAt: Long) =
        WorkoutSession(routineName = "R", startedAt = startedAt, finishedAt = startedAt + 1000)

    @Test fun streak_countsConsecutiveDaysAcrossSpringForward() {
        useEastern()
        // Sessions on the 12th, 13th, 14th (the 23h DST day). "Now" = the 14th. A fixed-24h cursor
        // step would mis-land after crossing the boundary and undercount; calendar step => 3.
        val history = listOf(
            session(noon(2021, Calendar.MARCH, 12)),
            session(noon(2021, Calendar.MARCH, 13)),
            session(noon(2021, Calendar.MARCH, 14)),
        )
        val streak = currentStreakAt(history, noon(2021, Calendar.MARCH, 14))
        assertEquals(3, streak)
    }

    @Test fun streak_brokenDayStopsCount() {
        useEastern()
        // 14th and 13th present, 12th missing -> streak of 2 ending today (14th).
        val history = listOf(
            session(noon(2021, Calendar.MARCH, 13)),
            session(noon(2021, Calendar.MARCH, 14)),
        )
        assertEquals(2, currentStreakAt(history, noon(2021, Calendar.MARCH, 14)))
    }

    @Test fun streak_zeroWhenNeitherTodayNorYesterday() {
        useEastern()
        val history = listOf(session(noon(2021, Calendar.MARCH, 10)))
        assertEquals(0, currentStreakAt(history, noon(2021, Calendar.MARCH, 14)))
    }

    @Test fun thisWeek_countsTrailingSevenCalendarDays() {
        useEastern()
        val now = noon(2021, Calendar.MARCH, 14) // window: 8th..14th inclusive
        val history = listOf(
            session(noon(2021, Calendar.MARCH, 14)), // in
            session(noon(2021, Calendar.MARCH, 8)),  // in (boundary, spans DST)
            session(noon(2021, Calendar.MARCH, 7)),  // out
        )
        assertEquals(2, thisWeekCountAt(history, now))
    }
}
