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
    /** Called when a FOCUS phase completes, with its length in minutes (persist + log). */
    var onFocusCompleted: (Int) -> Unit = {},
) {
    var focusMinutes by mutableStateOf(focusMinutes); private set
    var breakMinutes by mutableStateOf(breakMinutes); private set
    var phase by mutableStateOf(PomodoroPhase.FOCUS); private set
    var isRunning by mutableStateOf(false); private set
    /** Seconds left in the current phase. */
    var remaining by mutableStateOf(focusMinutes * 60.0); private set

    private var endTime: Long? = null // epoch millis

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

    fun start() {
        if (isRunning) return
        if (remaining <= 0) remaining = phaseDuration
        endTime = System.currentTimeMillis() + (remaining * 1000).toLong()
        isRunning = true
    }

    fun pause() {
        if (!isRunning) return
        sync()
        isRunning = false
        endTime = null
    }

    /** Stop and return to the top of the FOCUS phase. */
    fun reset() {
        isRunning = false
        endTime = null
        phase = PomodoroPhase.FOCUS
        remaining = phaseDuration
    }

    /** Called ~4x/sec by the UI ticker: recompute remaining from the wall clock. */
    fun tick() = sync()

    private fun sync() {
        val end = endTime ?: return
        remaining = (end - System.currentTimeMillis()) / 1000.0
        if (remaining <= 0) completePhase()
    }

    private fun completePhase() {
        val finished = phase
        if (finished == PomodoroPhase.FOCUS) onFocusCompleted(focusMinutes)
        phase = if (finished == PomodoroPhase.FOCUS) PomodoroPhase.BREAK else PomodoroPhase.FOCUS
        remaining = phaseDuration
        endTime = if (isRunning) System.currentTimeMillis() + (remaining * 1000).toLong() else null
    }

    /** Apply persisted lengths from settings; re-seed an idle timer so a new length shows now. */
    fun applyDurations(focusMinutes: Int, breakMinutes: Int) {
        this.focusMinutes = focusMinutes
        this.breakMinutes = breakMinutes
        if (!isRunning) remaining = phaseDuration
    }
}
