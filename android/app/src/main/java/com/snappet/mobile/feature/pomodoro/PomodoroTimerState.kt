package com.snappet.mobile.feature.pomodoro

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.math.ceil

/** The two phases of a Pomodoro cycle. */
enum class PomodoroPhase(val title: String) { FOCUS("Focus"), BREAK("Break") }

/**
 * Drift-free Pomodoro countdown engine. Rather than decrementing a counter each tick (which
 * accumulates error), it stores an absolute [endTime] and derives [remaining] from wall-clock
 * time on every [tick]; the 1s UI ticker only drives refreshes. Pause captures the remaining
 * interval; resume rebuilds [endTime]. State is Compose-observable. Mirrors iOS `PomodoroTimer`.
 */
class PomodoroTimerState(
    focusMinutes: Int,
    breakMinutes: Int,
    /** Called when a FOCUS phase completes: its length in minutes + the boundary's true
     *  absolute end (epoch millis) — a catch-up walk after a night away must log each
     *  session on the day it actually finished, not at restore time (issue #85 review). */
    var onFocusCompleted: (Int, Long) -> Unit = { _, _ -> },
    /**
     * Fires whenever the wall-clock schedule changes: a phase starts or auto-advances (the
     * phase now running + its absolute end, epoch millis), or the countdown stops (`null`
     * on pause/reset). The container wires this to persistence + the foreground-service
     * notification + the phase-end alarm, so background alerting can't drift from the
     * in-app timer (issue #85; mirrors iOS `onScheduleChanged`).
     */
    var onScheduleChanged: (PomodoroPhase, Long?) -> Unit = { _, _ -> },
) {
    var focusMinutes by mutableStateOf(focusMinutes); private set
    var breakMinutes by mutableStateOf(breakMinutes); private set
    var phase by mutableStateOf(PomodoroPhase.FOCUS); private set
    var isRunning by mutableStateOf(false); private set
    /** Seconds left in the current phase. */
    var remaining by mutableStateOf(focusMinutes * 60.0); private set

    /** Absolute end of the running phase (epoch millis); null while idle/paused. */
    var endTime: Long? = null // epoch millis
        private set
    /** Paused mid-phase (vs idle at the top of one) — `applyDurations` must not reseed over it. */
    var isPaused: Boolean = false
        private set

    /** Total seconds in the current phase — used for the progress ring. */
    val phaseDuration: Double
        get() = (if (phase == PomodoroPhase.FOCUS) focusMinutes else breakMinutes) * 60.0

    /** Fraction of the current phase remaining, clamped 0..1. */
    val progress: Double
        get() = if (phaseDuration > 0) (remaining / phaseDuration).coerceIn(0.0, 1.0) else 0.0

    val timeText: String
        get() {
            val total = ceil(remaining).toInt().coerceAtLeast(0)
            return "%02d:%02d".format(total / 60, total % 60)
        }

    fun start(now: Long = System.currentTimeMillis()) {
        if (isRunning || phaseDuration <= 0) return
        if (remaining <= 0) remaining = phaseDuration
        endTime = now + (remaining * 1000).toLong()
        isRunning = true
        isPaused = false
        onScheduleChanged(phase, endTime)
    }

    fun pause(now: Long = System.currentTimeMillis()) {
        if (!isRunning) return
        sync(now)
        isRunning = false
        isPaused = true
        endTime = null
        onScheduleChanged(phase, null)
    }

    /** Stop and return to the top of the FOCUS phase. */
    fun reset() {
        isRunning = false
        isPaused = false
        endTime = null
        phase = PomodoroPhase.FOCUS
        remaining = phaseDuration
        onScheduleChanged(phase, null)
    }

    /**
     * Re-attach to a phase that persisted state says is (or was) running — process death
     * or a container rebuild. A future end resumes the countdown; a past end walks the
     * elapsed boundaries via [sync] so phases that completed while away are logged and
     * the timer lands mid-whatever-phase the wall clock says.
     */
    fun restore(phase: PomodoroPhase, endTimeMillis: Long, now: Long = System.currentTimeMillis()) {
        if (isRunning) return
        this.phase = phase
        this.endTime = endTimeMillis
        this.remaining = ((endTimeMillis - now) / 1000.0).coerceAtLeast(0.0)
        isRunning = true
        isPaused = false
        if (endTimeMillis <= now) sync(now) else onScheduleChanged(phase, endTimeMillis)
    }

    /** Restore a PAUSED session's progress (process death while paused). */
    fun restorePaused(phase: PomodoroPhase, remainingSeconds: Double) {
        if (isRunning) return
        this.phase = phase
        this.remaining = remainingSeconds.coerceAtLeast(0.0)
        isPaused = true
    }

    /** Called ~4x/sec by the UI ticker: recompute remaining from the wall clock. */
    fun tick(now: Long = System.currentTimeMillis()) = sync(now)

    /**
     * Recompute from the wall clock; walk **every** phase boundary that elapsed while
     * ticks were suspended — each next phase anchored at the *previous phase's end*, not
     * at catch-up time, so returning after a long lock lands mid-whatever-phase the wall
     * clock says (issue #85; the iOS engine got the same fix in #70's review).
     */
    private fun sync(now: Long = System.currentTimeMillis()) {
        var end = endTime ?: return
        remaining = (end - now) / 1000.0
        if (remaining > 0) return
        // A degenerate duration can't advance — bail rather than re-emitting the same
        // past schedule (and its notifications) on every tick (issue #85 review).
        if (phaseDuration <= 0) return

        while (end <= now && phaseDuration > 0) {
            val finished = phase
            if (finished == PomodoroPhase.FOCUS) onFocusCompleted(focusMinutes, end)
            phase = if (finished == PomodoroPhase.FOCUS) PomodoroPhase.BREAK else PomodoroPhase.FOCUS
            end += (phaseDuration * 1000).toLong()
        }
        endTime = end
        remaining = (end - now) / 1000.0
        onScheduleChanged(phase, end)
    }

    /** Apply persisted lengths from settings; re-seed an idle timer so a new length shows
     *  now — but never over a *paused* session's progress. */
    fun applyDurations(focusMinutes: Int, breakMinutes: Int) {
        this.focusMinutes = focusMinutes
        this.breakMinutes = breakMinutes
        if (!isRunning && !isPaused) remaining = phaseDuration
    }
}
