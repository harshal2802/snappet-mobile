package com.snappet.mobile.feature.kilter

import android.content.Context

/**
 * Persisted catalog filters (layout, angle, grade range), surviving relaunches — the Android
 * analogue of the iOS `@AppStorage` keys `kilter.layout/angle/minGrade/maxGrade`. Backed by
 * SharedPreferences (not the Room store). Mirrors the Tip/Pomodoro settings pattern.
 */
object KilterSettings {
    private fun prefs(context: Context) = context.getSharedPreferences("kilter", Context.MODE_PRIVATE)

    fun layout(context: Context): Int = prefs(context).getInt("layout", 1)
    fun setLayout(context: Context, value: Int) = prefs(context).edit().putInt("layout", value).apply()

    fun angle(context: Context): Int = prefs(context).getInt("angle", 40)
    fun setAngle(context: Context, value: Int) = prefs(context).edit().putInt("angle", value).apply()

    fun minGrade(context: Context): Int = prefs(context).getInt("minGrade", 10)
    fun setMinGrade(context: Context, value: Int) = prefs(context).edit().putInt("minGrade", value).apply()

    fun maxGrade(context: Context): Int = prefs(context).getInt("maxGrade", 33)
    fun setMaxGrade(context: Context, value: Int) = prefs(context).edit().putInt("maxGrade", value).apply()

    fun gradeFormat(context: Context): KilterGradeFormat =
        KilterGradeFormat.from(prefs(context).getString("gradeFormat", null))
    fun setGradeFormat(context: Context, value: KilterGradeFormat) =
        prefs(context).edit().putString("gradeFormat", value.name).apply()
}
