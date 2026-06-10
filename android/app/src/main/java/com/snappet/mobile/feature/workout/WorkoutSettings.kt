package com.snappet.mobile.feature.workout

import android.content.Context

/**
 * Persisted Workout Tracker preferences (currently the preferred weight unit), surviving relaunches
 * via SharedPreferences — the Android analogue of the iOS `@AppStorage("workoutlog.preferredUnit")`.
 */
object WorkoutSettings {
    private fun prefs(context: Context) =
        context.getSharedPreferences("workoutlog", Context.MODE_PRIVATE)

    fun preferredUnit(context: Context): WorkoutWeightUnit =
        WorkoutWeightUnit.from(prefs(context).getString("preferredUnit", WorkoutWeightUnit.KG.raw))

    fun setPreferredUnit(context: Context, unit: WorkoutWeightUnit) =
        prefs(context).edit().putString("preferredUnit", unit.raw).apply()

    /** Starter keys the user deleted — `seedIfNeeded` must not resurrect them (the iOS
     *  `dismissedStarters` tombstone, ported; issue #88 review). */
    fun dismissedStarters(context: Context): Set<String> =
        prefs(context).getStringSet("dismissedStarters", emptySet()) ?: emptySet()

    fun dismissStarter(context: Context, key: String) =
        prefs(context).edit()
            .putStringSet("dismissedStarters", dismissedStarters(context) + key)
            .apply()
}
