package com.snappet.mobile.feature.pomodoro

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The issue-#85 reliability seams of the pure Pomodoro engine: the schedule callback
 * (what persistence/notifications/alarms hang off), wall-clock catch-up across suspended
 * boundaries, restore-from-persisted-state, and paused-progress preservation. All
 * wall-clock injected — no device, no Compose host.
 */
class PomodoroTimerStateTest {

    private fun timer(focus: Int = 25, brk: Int = 5) = PomodoroTimerState(focus, brk)

    @Test
    fun startFiresScheduleWithAbsoluteEnd() {
        val t = timer()
        val events = mutableListOf<Pair<PomodoroPhase, Long?>>()
        t.onScheduleChanged = { p, e -> events.add(p to e) }

        t.start(now = 1_000_000L)

        assertEquals(1, events.size)
        assertEquals(PomodoroPhase.FOCUS, events[0].first)
        assertEquals(1_000_000L + 25 * 60_000L, events[0].second)
    }

    @Test
    fun pauseAndResetFireNullSchedule() {
        val t = timer()
        val events = mutableListOf<Pair<PomodoroPhase, Long?>>()
        t.onScheduleChanged = { p, e -> events.add(p to e) }

        t.start(now = 0L)
        t.pause(now = 60_000L)
        assertNull(events.last().second)
        assertTrue(t.isPaused)
        assertEquals(24 * 60.0, t.remaining, 0.01)

        t.reset()
        assertNull(events.last().second)
        assertFalse(t.isPaused)
        assertEquals(25 * 60.0, t.remaining, 0.01)
    }

    @Test
    fun applyDurationsPreservesPausedProgress() {
        val t = timer()
        t.start(now = 0L)
        t.pause(now = 5 * 60_000L)   // 20:00 left
        t.applyDurations(50, 10)
        assertEquals(20 * 60.0, t.remaining, 0.01)

        t.reset()
        t.applyDurations(50, 10)
        assertEquals(50 * 60.0, t.remaining, 0.01)
    }

    @Test
    fun catchUpWalksBoundariesAnchoredAtPhaseEnds() {
        val t = timer(focus = 25, brk = 5)
        var focusCompletions = 0
        t.onFocusCompleted = { _, _ -> focusCompletions += 1 }
        t.start(now = 0L)

        // Locked through the whole focus + 2 min of break: land 3 min FROM the break's
        // end (anchored at +25), not a fresh phase from "now".
        t.tick(now = 27 * 60_000L)
        assertEquals(PomodoroPhase.BREAK, t.phase)
        assertEquals(1, focusCompletions)
        assertEquals(3 * 60.0, t.remaining, 0.5)

        // Through the break and into focus #2 (+30..+55): at +32 there are ~23 min left.
        t.tick(now = 32 * 60_000L)
        assertEquals(PomodoroPhase.FOCUS, t.phase)
        assertEquals(1, focusCompletions)
        assertEquals(23 * 60.0, t.remaining, 0.5)
    }

    @Test
    fun restoreResumesAFutureEnd() {
        val t = timer()
        t.restore(PomodoroPhase.BREAK, endTimeMillis = 10 * 60_000L, now = 7 * 60_000L)
        assertTrue(t.isRunning)
        assertEquals(PomodoroPhase.BREAK, t.phase)
        assertEquals(3 * 60.0, t.remaining, 0.01)
    }

    @Test
    fun restoreWithPastEndCatchesUpAndLogsTheFocus() {
        val t = timer(focus = 25, brk = 5)
        var logged = 0
        var loggedAt = 0L
        t.onFocusCompleted = { _, at -> logged += 1; loggedAt = at }

        // Process died mid-focus; the phase ended at +25 and we reopen at +26.
        t.restore(PomodoroPhase.FOCUS, endTimeMillis = 25 * 60_000L, now = 26 * 60_000L)

        assertEquals(1, logged)                      // the away-completed focus IS logged
        assertEquals(25 * 60_000L, loggedAt)         // ...stamped at its TRUE end, not restore time
        assertEquals(PomodoroPhase.BREAK, t.phase)   // and we land mid-break
        assertEquals(4 * 60.0, t.remaining, 0.5)
        assertNotNull(t.endTime)
    }

    @Test
    fun restorePausedKeepsProgressWithoutRunning() {
        val t = timer()
        t.restorePaused(PomodoroPhase.FOCUS, remainingSeconds = 12 * 60.0)
        assertFalse(t.isRunning)
        assertTrue(t.isPaused)
        assertEquals(12 * 60.0, t.remaining, 0.01)
    }

    @Test
    fun zeroDurationNeverStartsOrStorms() {
        val t = timer(focus = 25, brk = 5)
        t.applyDurations(0, 5)
        var scheduleEvents = 0
        t.onScheduleChanged = { _, _ -> scheduleEvents += 1 }
        t.start(now = 0L)
        assertFalse(t.isRunning)
        assertEquals(0, scheduleEvents)
    }

    // The receivers' boundary chain must agree with the engine's walk — same anchors.
    @Test
    fun scheduleWalkMatchesEngineCatchUp() {
        // Anchor: FOCUS ending at 25min; focus 25 / break 5.
        val at27 = PomodoroSchedule.at(PomodoroPhase.FOCUS, 25 * 60_000L, 25, 5, now = 27 * 60_000L)
        assertEquals(PomodoroPhase.FOCUS, at27.endedPhase)
        assertEquals(PomodoroPhase.BREAK, at27.phase)
        assertEquals(30 * 60_000L, at27.endTimeMillis)

        val at32 = PomodoroSchedule.at(PomodoroPhase.FOCUS, 25 * 60_000L, 25, 5, now = 32 * 60_000L)
        assertEquals(PomodoroPhase.BREAK, at32.endedPhase)
        assertEquals(PomodoroPhase.FOCUS, at32.phase)
        assertEquals(55 * 60_000L, at32.endTimeMillis)

        // Future anchor: nothing ended, alarm target unchanged.
        val early = PomodoroSchedule.at(PomodoroPhase.FOCUS, 25 * 60_000L, 25, 5, now = 10 * 60_000L)
        assertNull(early.endedPhase)
        assertEquals(25 * 60_000L, early.endTimeMillis)
    }

    // The phase-end notification copy is pure — lock it (mirrors iOS).
    @Test
    fun phaseEndCopy() {
        assertEquals("Focus complete" to "Nice work — time for a break.",
                     PomodoroAlerts.phaseEndContent(PomodoroPhase.FOCUS))
        assertEquals("Break's over" to "Back to focus.",
                     PomodoroAlerts.phaseEndContent(PomodoroPhase.BREAK))
    }
}
