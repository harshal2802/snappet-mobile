package com.snappet.mobile.feature.nutrition

/**
 * Pure calorie budget snapshot — no Android / Compose imports so it is testable on any JVM host.
 * Mirrors iOS `NutritionBudget` struct.
 */
data class NutritionBudget(
    val consumedKcal: Double,
    val goalKcal: Int,
    val activeBurnedKcal: Double = 0.0,
) {
    val remainingKcal: Double get() = goalKcal + activeBurnedKcal - consumedKcal
    val netKcal: Double get() = consumedKcal - activeBurnedKcal
    val ringFraction: Float get() =
        if (goalKcal == 0) 0f else (consumedKcal / goalKcal).coerceIn(0.0, 1.0).toFloat()

    companion object {
        /** Mifflin–St Jeor BMR (kcal/day). Used as HealthKit active-burn fallback. */
        fun mifflinBmr(weightKg: Double, heightCm: Double, ageYears: Int, isMale: Boolean): Double {
            val base = 10 * weightKg + 6.25 * heightCm - 5 * ageYears
            return if (isMale) base + 5 else base - 161
        }
    }
}
