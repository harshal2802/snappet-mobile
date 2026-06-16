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

    /** The user's physical board size (`product_size_id`). 0 = unset → falls back to the layout default;
     *  drives which LED map is sent so the right holds light. */
    fun productSizeId(context: Context): Int = prefs(context).getInt("productSizeId", 0)
    fun setProductSizeId(context: Context, value: Int) =
        prefs(context).edit().putInt("productSizeId", value).apply()

    // Download-sheet picks (your board) — persisted so re-opening restores them, matching iOS @AppStorage.
    fun dlLayout(context: Context): Int = prefs(context).getInt("dl.layout", 1)
    fun setDlLayout(context: Context, value: Int) = prefs(context).edit().putInt("dl.layout", value).apply()
    fun dlSizeId(context: Context): Int = prefs(context).getInt("dl.sizeId", 10)
    fun setDlSizeId(context: Context, value: Int) = prefs(context).edit().putInt("dl.sizeId", value).apply()
    fun dlMaxClimbs(context: Context): Int = prefs(context).getInt("dl.maxClimbs", 2000)
    fun setDlMaxClimbs(context: Context, value: Int) = prefs(context).edit().putInt("dl.maxClimbs", value).apply()

    fun minGrade(context: Context): Int = prefs(context).getInt("minGrade", 10)
    fun setMinGrade(context: Context, value: Int) = prefs(context).edit().putInt("minGrade", value).apply()

    fun maxGrade(context: Context): Int = prefs(context).getInt("maxGrade", 33)
    fun setMaxGrade(context: Context, value: Int) = prefs(context).edit().putInt("maxGrade", value).apply()

    fun gradeFormat(context: Context): KilterGradeFormat =
        KilterGradeFormat.from(prefs(context).getString("gradeFormat", null))
    fun setGradeFormat(context: Context, value: KilterGradeFormat) =
        prefs(context).edit().putString("gradeFormat", value.name).apply()

    /** Board payload dialect (Standard/Legacy). Defaults to V3 — what current boards use. */
    fun apiLevel(context: Context): KilterProtocol.ApiLevel =
        KilterProtocol.ApiLevel.from(prefs(context).getString("apiLevel", null))
    fun setApiLevel(context: Context, value: KilterProtocol.ApiLevel) =
        prefs(context).edit().putString("apiLevel", value.name).apply()

    // Plan-config (bug #4): last-used selection strategy + the knobs it seeds. Defaults reproduce the
    // original behaviour (balanced / 6 climbs / at-grade / prefer-unsent).
    fun planStrategy(context: Context): String = prefs(context).getString("plan.strategy", "BALANCED") ?: "BALANCED"
    fun setPlanStrategy(context: Context, value: String) = prefs(context).edit().putString("plan.strategy", value).apply()
    fun planTargetCount(context: Context): Int = prefs(context).getInt("plan.targetCount", 6)
    fun setPlanTargetCount(context: Context, value: Int) = prefs(context).edit().putInt("plan.targetCount", value).apply()
    fun planGradeOffset(context: Context): Int = prefs(context).getInt("plan.gradeOffset", 0)
    fun setPlanGradeOffset(context: Context, value: Int) = prefs(context).edit().putInt("plan.gradeOffset", value).apply()
    fun planPreferUnsent(context: Context): Boolean = prefs(context).getBoolean("plan.preferUnsent", true)
    fun setPlanPreferUnsent(context: Context, value: Boolean) = prefs(context).edit().putBoolean("plan.preferUnsent", value).apply()
}
