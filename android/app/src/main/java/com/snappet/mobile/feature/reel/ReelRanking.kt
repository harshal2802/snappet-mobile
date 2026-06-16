package com.snappet.mobile.feature.reel

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The first **pipeline slice** of Workout Reels (issue #90): a pure, platform-free port of the iOS
 * `HighlightEngine` ranking core — resample → smooth → %HRR → score → pick non-overlapping high-HR
 * windows. No Android / Health Connect / Media3 deps, so it is JVM-unit-tested without a device, the
 * same way the iOS `HighlightEngine` is a Foundation-only SPM package. The device-only edges (read
 * the HR series from Health Connect, find media in the workout window, assemble with Media3) plug
 * into this core later.
 */
object ReelRanking {

    /** A raw heart-rate sample: `t` seconds from workout start, `bpm`. */
    data class HRPoint(val t: Double, val bpm: Double)

    /** A selected highlight window (seconds from workout start) and its peak %HRR score (0..1). */
    data class Highlight(val startSec: Double, val endSec: Double, val score: Double)

    /**
     * Tunables mirroring the iOS climbing/workout `HighlightConfig` preset (the ones this core reads).
     * @property smoothingWindowSec centered moving-average window.
     * @property clipLeadSec / clipTrailSec seconds of context around a peak.
     * @property minGapSec minimum gap between two highlights (avoid overlapping clips).
     * @property maxHighlights cap on returned highlights.
     */
    data class Config(
        val smoothingWindowSec: Double = 5.0,
        val clipLeadSec: Double = 4.0,
        val clipTrailSec: Double = 3.0,
        val minGapSec: Double = 15.0,
        val maxHighlights: Int = 10,
    )

    private const val DT = 1.0  // 1 Hz resample grid (matches the iOS climbing path)

    /**
     * Rank a workout's HR series into the top non-overlapping high-intensity windows.
     * @param restBpm optional resting HR floor; defaults to the 5th-percentile of the smoothed series.
     * @param maxBpm optional max HR ceiling; defaults to the 99th-percentile.
     */
    fun rank(
        samples: List<HRPoint>,
        config: Config = Config(),
        restBpm: Double? = null,
        maxBpm: Double? = null,
    ): List<Highlight> {
        if (samples.isEmpty()) return emptyList()
        val sorted = samples.sortedBy { it.t }
        val duration = sorted.last().t.coerceAtLeast(DT)
        val n = maxOf(1, (duration / DT).roundToInt())

        // 1. Resample onto a uniform grid (linear interpolation; hold the last value past the end).
        val grid = DoubleArray(n) { i ->
            val t = i * DT
            interpolate(sorted, t)
        }

        // 2. Smooth (centered moving average).
        val w = maxOf(1, (config.smoothingWindowSec / DT).roundToInt())
        val half = w / 2
        val smoothed = DoubleArray(n) { i ->
            val lo = (i - half).coerceAtLeast(0)
            val hi = (i + half).coerceAtMost(n - 1)
            var sum = 0.0
            for (j in lo..hi) sum += grid[j]
            sum / (hi - lo + 1)
        }

        // 3. rest / max baselines, then %HRR per grid point.
        val rest = restBpm ?: percentile(smoothed, 0.05)
        val mx = maxBpm ?: maxOf(percentile(smoothed, 0.99), rest + 1)
        val hrr = DoubleArray(n) { i ->
            ((smoothed[i] - rest) / (mx - rest).coerceAtLeast(1e-6)).coerceIn(0.0, 1.0)
        }

        // 4. Greedy non-overlapping peak selection by descending %HRR, enforcing minGap.
        val order = (0 until n).sortedByDescending { hrr[it] }
        val chosen = ArrayList<Int>()
        for (idx in order) {
            if (chosen.size >= config.maxHighlights) break
            val tIdx = idx * DT
            if (chosen.any { abs(it * DT - tIdx) < config.minGapSec }) continue
            if (hrr[idx] <= 0.0) continue
            chosen.add(idx)
        }

        return chosen.sorted().map { idx ->
            val peakT = idx * DT
            Highlight(
                startSec = (peakT - config.clipLeadSec).coerceAtLeast(0.0),
                endSec = (peakT + config.clipTrailSec).coerceAtMost(duration),
                score = hrr[idx],
            )
        }
    }

    private fun interpolate(sorted: List<HRPoint>, t: Double): Double {
        if (t <= sorted.first().t) return sorted.first().bpm
        if (t >= sorted.last().t) return sorted.last().bpm
        // Find the bracketing pair.
        var j = 0
        while (j < sorted.size - 1 && sorted[j + 1].t <= t) j++
        val a = sorted[j]
        val b = sorted[minOf(j + 1, sorted.size - 1)]
        val span = (b.t - a.t).coerceAtLeast(1e-6)
        val f = ((t - a.t) / span).coerceIn(0.0, 1.0)
        return a.bpm + (b.bpm - a.bpm) * f
    }

    private fun percentile(xs: DoubleArray, p: Double): Double {
        if (xs.isEmpty()) return 0.0
        val sorted = xs.sorted()
        val idx = (p * (sorted.size - 1)).roundToInt().coerceIn(0, sorted.size - 1)
        return sorted[idx]
    }
}
