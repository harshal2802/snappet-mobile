package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.hr.HRSample
import com.snappet.mobile.feature.kilter.hr.HRStats
import com.snappet.mobile.feature.kilter.hr.HRVMetrics
import com.snappet.mobile.feature.kilter.hr.HeartRateZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HeartRateZoneTest {

    @Test fun zoneBoundaries_lowerInclusive_at190Max() {
        // %max: <0.60 recovery, 0.60 easy, 0.70 aerobic, 0.80 threshold, 0.90 max.
        assertEquals(HeartRateZone.RECOVERY, HeartRateZone.forBpm(100))  // 0.526
        assertEquals(HeartRateZone.EASY, HeartRateZone.forBpm(114))      // exactly 0.60
        assertEquals(HeartRateZone.AEROBIC, HeartRateZone.forBpm(133))   // exactly 0.70
        assertEquals(HeartRateZone.THRESHOLD, HeartRateZone.forBpm(152)) // exactly 0.80
        assertEquals(HeartRateZone.MAX, HeartRateZone.forBpm(171))       // exactly 0.90
    }

    @Test fun noneSentinel() {
        assertEquals(HeartRateZone.NONE, HeartRateZone.forBpm(null))
        assertEquals(HeartRateZone.NONE, HeartRateZone.forBpm(0))
        assertEquals(HeartRateZone.NONE, HeartRateZone.forBpm(120, maxHR = 0))
    }

    @Test fun pillLabel() {
        assertEquals("Z3 · Aerobic", HeartRateZone.AEROBIC.pillLabel)
        assertEquals("—", HeartRateZone.NONE.pillLabel)
    }

    @Test fun hrStats_avgMaxMin_andLeftEdgeDwell() {
        val series = listOf(
            HRSample(0.0, 100), HRSample(10.0, 160), HRSample(20.0, 180),
        )
        val s = HRStats.make(series, maxHR = 190)!!
        assertEquals(146, s.avgBpm)   // (100+160+180)/3 = 146.67 → 146
        assertEquals(180, s.maxBpm)
        assertEquals(100, s.minBpm)
        // First sample (100 bpm, recovery) owns [0,10) = 10s; second (160, threshold) owns [10,20)=10s.
        assertEquals(10.0, s.secondsByZone[HeartRateZone.RECOVERY]!!, 1e-6)
        assertEquals(10.0, s.secondsByZone[HeartRateZone.THRESHOLD]!!, 1e-6)
    }

    @Test fun hrStats_emptyIsNull() {
        assertNull(HRStats.make(emptyList()))
    }

    @Test fun hrv_populationVarianceAndRmssd() {
        // Five plausible RR intervals.
        val rr = listOf(800.0, 810.0, 790.0, 805.0, 795.0)
        val m = HRVMetrics.make(rr)
        assertEquals(5, m.beatCount)
        assertTrue(m.sdnn!! > 0.0)
        assertTrue(m.rmssd!! > 0.0)
    }

    @Test fun hrv_dropsImplausibleAndTooFew() {
        // After filtering only 1 plausible interval remains → empty.
        val m = HRVMetrics.make(listOf(100.0, 5000.0, 850.0))
        assertEquals(HRVMetrics.EMPTY, m)
    }
}
