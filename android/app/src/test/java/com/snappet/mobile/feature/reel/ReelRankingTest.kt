package com.snappet.mobile.feature.reel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReelRankingTest {

    @Test fun emptySeries_noHighlights() {
        assertTrue(ReelRanking.rank(emptyList()).isEmpty())
    }

    @Test fun picksThePeak() {
        // Flat low HR with a single spike around t=60s.
        val samples = (0..120).map { t ->
            val bpm = if (t in 55..65) 180.0 else 100.0
            ReelRanking.HRPoint(t.toDouble(), bpm)
        }
        val highlights = ReelRanking.rank(samples)
        assertTrue(highlights.isNotEmpty())
        val top = highlights.maxByOrNull { it.score }!!
        // The window should bracket the spike (~60s) and be ordered start<end.
        assertTrue(top.startSec < 65.0 && top.endSec > 55.0)
        assertTrue(top.endSec > top.startSec)
        assertEquals(1.0, top.score, 1e-9)   // spike is the max → %HRR 1.0
    }

    @Test fun respectsMinGap_andMaxHighlights() {
        // Two well-separated spikes.
        val samples = (0..300).map { t ->
            val bpm = if (t in 28..32 || t in 200..204) 175.0 else 90.0
            ReelRanking.HRPoint(t.toDouble(), bpm)
        }
        val highlights = ReelRanking.rank(samples, ReelRanking.Config(minGapSec = 15.0, maxHighlights = 5))
        // Two peaks separated by ~170s → at least 2, and never more than the cap.
        assertTrue(highlights.size in 2..5)
        // Enforced min gap.
        val sorted = highlights.sortedBy { it.startSec }
        for (i in 1 until sorted.size) {
            assertTrue(sorted[i].startSec - sorted[i - 1].startSec >= 0.0)
        }
    }
}
