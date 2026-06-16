package com.snappet.mobile.feature.kilter.hr

import kotlin.math.sqrt

/**
 * One heart-rate sample on a session-relative time grid.
 * @property t seconds from session start.
 * @property bpm beats per minute.
 * @property rrIntervalsMs RR intervals (ms) carried by this packet, when the source is a trusted
 *   chest strap (RR is dropped for wrist/optical sources — see [BleHeartRateSource]).
 */
data class HRSample(
    val t: Double,
    val bpm: Int,
    val rrIntervalsMs: List<Double>? = null,
)

/**
 * Time-in-zone summary over a session's HR series. Ported from the iOS `WorkoutHRStats`
 * (`WorkoutHRStats.swift`): left-edge dwell attribution, Edwards TRIMP, redline fraction. Pure,
 * JVM-unit-tested. Returns `null` for an empty series.
 */
data class HRStats(
    val avgBpm: Int,
    val maxBpm: Int,
    val minBpm: Int,
    /** Seconds spent in each zone (RECOVERY..MAX), in order; index 0 = RECOVERY. */
    val secondsByZone: Map<HeartRateZone, Double>,
) {
    val totalSeconds: Double get() = secondsByZone.values.sum()

    /** Threshold + Max seconds — the "redline" time. */
    val redlineSeconds: Double
        get() = (secondsByZone[HeartRateZone.THRESHOLD] ?: 0.0) +
            (secondsByZone[HeartRateZone.MAX] ?: 0.0)

    val redlineFraction: Double
        get() = if (totalSeconds > 0) redlineSeconds / totalSeconds else 0.0

    /** Edwards TRIMP: Σ minutes-in-zone × zone number (recovery=1 … max=5). */
    val edwardsTRIMP: Double
        get() = secondsByZone.entries.sumOf { (zone, secs) -> (secs / 60.0) * zone.rawValue }

    companion object {
        fun make(series: List<HRSample>, maxHR: Int = HeartRateZone.DEFAULT_MAX_HR): HRStats? {
            if (series.isEmpty()) return null
            val sorted = series.sortedBy { it.t }
            val avg = sorted.map { it.bpm }.average().toInt()
            val max = sorted.maxOf { it.bpm }
            val min = sorted.minOf { it.bpm }

            // Left-edge dwell attribution: each sample owns the interval until the next one.
            val byZone = HeartRateZone.entries.filter { it != HeartRateZone.NONE }
                .associateWith { 0.0 }.toMutableMap()
            for (i in 0 until sorted.size - 1) {
                val dwell = (sorted[i + 1].t - sorted[i].t).coerceAtLeast(0.0)
                if (dwell == 0.0) continue
                val zone = HeartRateZone.forBpm(sorted[i].bpm, maxHR)
                if (zone == HeartRateZone.NONE) continue
                byZone[zone] = (byZone[zone] ?: 0.0) + dwell
            }
            return HRStats(avgBpm = avg, maxBpm = max, minBpm = min, secondsByZone = byZone)
        }
    }
}

/**
 * Minimal HRV (RMSSD / SDNN) over a list of RR intervals, ported from the iOS `HRVMetrics`. Used in
 * the per-climb-rest readout when a trusted strap supplies RR. Pure, JVM-tested.
 * Gotcha parity: SDNN uses **population** variance (÷N); RMSSD divides by pairs (N-1).
 */
data class HRVMetrics(
    val rmssd: Double?,
    val sdnn: Double?,
    val beatCount: Int,
) {
    companion object {
        val EMPTY = HRVMetrics(null, null, 0)
        private val PLAUSIBLE = 300.0..2000.0

        fun make(rrIntervalsMs: List<Double>, minIntervals: Int = 5): HRVMetrics {
            val filtered = rrIntervalsMs.filter { it in PLAUSIBLE }
            if (filtered.size < maxOf(2, minIntervals)) return EMPTY
            val mean = filtered.average()
            val variance = filtered.sumOf { (it - mean) * (it - mean) } / filtered.size  // population (÷N)
            val sdnn = sqrt(variance)
            var sumSqDiff = 0.0
            for (i in 1 until filtered.size) {
                val d = filtered[i] - filtered[i - 1]
                sumSqDiff += d * d
            }
            val pairs = filtered.size - 1
            val rmssd = sqrt(sumSqDiff / pairs)
            return HRVMetrics(rmssd = rmssd, sdnn = sdnn, beatCount = filtered.size)
        }
    }
}
