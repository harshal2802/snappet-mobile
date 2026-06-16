package com.snappet.mobile.feature.kilter.hr

/**
 * The five training zones as a fraction of max HR, plus a `NONE` sentinel for "no sample". Ported
 * from the iOS `HeartRateZone` (`ios/App/Shared/HeartRateZone.swift`) — same boundaries (lower-bound
 * inclusive), same default max HR, same colors — so the Kilter HR pill and session detail read the
 * same zones as iOS. Pure, JVM-unit-tested.
 */
enum class HeartRateZone(val rawValue: Int, val label: String, val colorHex: Long) {
    NONE(0, "—", 0xFF8E8E93),
    RECOVERY(1, "Recovery", 0xFF007AFF),
    EASY(2, "Easy", 0xFF30B0C7),
    AEROBIC(3, "Aerobic", 0xFF34C759),
    THRESHOLD(4, "Threshold", 0xFFFF9500),
    MAX(5, "Max", 0xFFFF3B30);

    /** `"Z{n} · {label}"`; NONE → "—". Mirrors iOS `pillLabel`. */
    val pillLabel: String get() = if (this == NONE) "—" else "Z$rawValue · $label"

    companion object {
        /** No-strap default used when the user hasn't set an HR profile (matches iOS). */
        const val DEFAULT_MAX_HR = 190

        /** Lower-bound-inclusive band of %-of-max. `bpm <= 0` or `maxHR <= 0` → [NONE]. */
        fun forBpm(bpm: Int?, maxHR: Int = DEFAULT_MAX_HR): HeartRateZone {
            if (bpm == null || bpm <= 0 || maxHR <= 0) return NONE
            val pct = bpm.toDouble() / maxHR.toDouble()
            return when {
                pct < 0.60 -> RECOVERY
                pct < 0.70 -> EASY
                pct < 0.80 -> AEROBIC
                pct < 0.90 -> THRESHOLD
                else -> MAX
            }
        }
    }
}
