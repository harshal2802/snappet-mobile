package com.snappet.mobile.feature.pomodoro

import android.content.Context

/**
 * Persists the running/paused Pomodoro session (phase + absolute end / paused remaining)
 * so navigation, rotation, and process death are invisible (issue #85). SharedPreferences
 * alongside [PomodoroSettings]; the engine stays pure — the container saves on every
 * `onScheduleChanged` and restores on first access.
 */
object PomodoroStateStore {
    private fun prefs(context: Context) =
        context.getSharedPreferences("pomodoro", Context.MODE_PRIVATE)

    sealed interface Saved {
        data class Running(val phase: PomodoroPhase, val endTimeMillis: Long) : Saved
        data class Paused(val phase: PomodoroPhase, val remainingSeconds: Double) : Saved
    }

    fun save(context: Context, phase: PomodoroPhase, endTimeMillis: Long?) {
        prefs(context).edit()
            .putString("state.phase", phase.name)
            .putLong("state.endTime", endTimeMillis ?: 0L)
            .apply()
    }

    fun savePaused(context: Context, phase: PomodoroPhase, remainingSeconds: Double) {
        prefs(context).edit()
            .putString("state.phase", phase.name)
            .putLong("state.endTime", 0L)
            .putLong("state.pausedRemainingMs", (remainingSeconds * 1000).toLong())
            .apply()
    }

    fun clear(context: Context) {
        prefs(context).edit()
            .remove("state.phase").remove("state.endTime").remove("state.pausedRemainingMs")
            .apply()
    }

    fun load(context: Context): Saved? {
        val p = prefs(context)
        val phase = p.getString("state.phase", null)
            ?.let { name -> runCatching { PomodoroPhase.valueOf(name) }.getOrNull() }
            ?: return null
        val end = p.getLong("state.endTime", 0L)
        if (end > 0L) return Saved.Running(phase, end)
        val pausedMs = p.getLong("state.pausedRemainingMs", 0L)
        if (pausedMs > 0L) return Saved.Paused(phase, pausedMs / 1000.0)
        return null
    }
}
