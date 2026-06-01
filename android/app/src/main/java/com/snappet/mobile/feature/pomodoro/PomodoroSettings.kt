package com.snappet.mobile.feature.pomodoro

import android.content.Context

/**
 * Persisted focus/break lengths (minutes), surviving relaunches — the Android analogue of the
 * iOS `@AppStorage` keys. Backed by SharedPreferences (not the Room store), so the UI test's
 * persistence check holds across an activity relaunch. Mirrors iOS keys `pomodoro.focusMinutes`
 * / `pomodoro.breakMinutes`.
 */
object PomodoroSettings {
    private fun prefs(context: Context) =
        context.getSharedPreferences("pomodoro", Context.MODE_PRIVATE)

    val focusRange = 5..90
    val breakRange = 1..30
    const val focusStep = 5
    const val breakStep = 1

    fun focusMinutes(context: Context): Int = prefs(context).getInt("focusMinutes", 25)
    fun breakMinutes(context: Context): Int = prefs(context).getInt("breakMinutes", 5)

    fun setFocusMinutes(context: Context, value: Int) =
        prefs(context).edit().putInt("focusMinutes", value.coerceIn(focusRange)).apply()

    fun setBreakMinutes(context: Context, value: Int) =
        prefs(context).edit().putInt("breakMinutes", value.coerceIn(breakRange)).apply()
}
