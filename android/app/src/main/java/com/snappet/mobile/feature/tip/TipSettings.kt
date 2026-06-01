package com.snappet.mobile.feature.tip

import android.content.Context

/**
 * Persisted, user-editable preset tip percentages, surviving relaunches — the Android analogue of
 * the iOS `@AppStorage` keys `tip.preset.0/1/2`. Backed by SharedPreferences (not the Room store),
 * so the preset-edit UI test's relative +1 check holds across an activity relaunch. Mirrors the
 * Pomodoro settings pattern.
 */
object TipSettings {
    private fun prefs(context: Context) =
        context.getSharedPreferences("tip", Context.MODE_PRIVATE)

    val presetRange = 0..100
    const val presetStep = 1

    private val defaults = intArrayOf(15, 18, 20)

    fun preset(context: Context, index: Int): Int =
        prefs(context).getInt("preset.$index", defaults[index])

    fun presets(context: Context): List<Int> = (0..2).map { preset(context, it) }

    fun setPreset(context: Context, index: Int, value: Int) =
        prefs(context).edit().putInt("preset.$index", value.coerceIn(presetRange)).apply()
}
