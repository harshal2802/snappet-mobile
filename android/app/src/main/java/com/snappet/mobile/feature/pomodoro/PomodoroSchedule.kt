package com.snappet.mobile.feature.pomodoro

/**
 * The boundary chain implied by a persisted schedule anchor (issue #85 review): given
 * the phase that was running and its absolute end, where is the session at `now`?
 * Pure — the alarm/boot receivers use it to chain alerts while the engine (and even the
 * process) is dead, and the engine's own restore walks the same anchors, so the two can
 * never disagree about which phase is running.
 */
object PomodoroSchedule {

    data class Position(
        /** The phase whose boundary most recently elapsed, or null if none did. */
        val endedPhase: PomodoroPhase?,
        /** The phase running at `now`. */
        val phase: PomodoroPhase,
        /** That phase's absolute end (epoch millis), strictly after `now`. */
        val endTimeMillis: Long,
    )

    fun at(
        anchorPhase: PomodoroPhase,
        anchorEndMillis: Long,
        focusMinutes: Int,
        breakMinutes: Int,
        now: Long,
    ): Position {
        var phase = anchorPhase
        var end = anchorEndMillis
        var ended: PomodoroPhase? = null
        // Guard degenerate durations so a bad setting can't loop forever.
        if (focusMinutes <= 0 || breakMinutes <= 0) return Position(null, phase, maxOf(end, now + 1))
        while (end <= now) {
            ended = phase
            phase = if (phase == PomodoroPhase.FOCUS) PomodoroPhase.BREAK else PomodoroPhase.FOCUS
            end += (if (phase == PomodoroPhase.FOCUS) focusMinutes else breakMinutes) * 60_000L
        }
        return Position(ended, phase, end)
    }
}
