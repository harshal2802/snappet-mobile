package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KilterSessionStatsTest {

    private fun log(name: String, grade: String, diff: Double, status: KilterAscentStatus,
                    attempts: Int = 1, at: Long) =
        KilterSessionStats.SessionLog("u-$name", name, grade, diff, status, attempts, at)

    @Test fun counts_pyramid_andHardest() {
        val start = 0L
        val end = 3_600_000L  // 1 hour
        val logs = listOf(
            log("A", "V4", 4.0, KilterAscentStatus.SENT, at = 1000),
            log("B", "V4", 4.0, KilterAscentStatus.FLASH, at = 2000),
            log("C", "V6", 6.0, KilterAscentStatus.SENT, at = 3000),
            log("D", "V8", 8.0, KilterAscentStatus.PROJECT, at = 4000),
            log("E", "V5", 5.0, KilterAscentStatus.ATTEMPT, attempts = 3, at = 5000),
        )
        val s = KilterSessionStats.make(logs, start, end)
        assertEquals(5, s.totalClimbs)
        assertEquals(3, s.sends)            // A, B, C
        assertEquals(1, s.projects)
        assertEquals(1, s.attemptsOnly)
        assertEquals(7, s.totalAttempts)    // 1+1+1+1+3
        assertEquals("V6", s.hardestSendGrade)
        // Pyramid sorted by difficulty asc: V4 (2 sends), V6 (1 send).
        assertEquals(listOf("V4" to 2, "V6" to 1), s.pyramid.map { it.gradeLabel to it.sends })
        assertEquals(3.0, s.sendsPerHour, 1e-6)  // 3 sends / 1 hour
    }

    @Test fun timeline_chronological() {
        val logs = listOf(
            log("Late", "V4", 4.0, KilterAscentStatus.SENT, at = 9000),
            log("Early", "V4", 4.0, KilterAscentStatus.SENT, at = 1000),
        )
        val s = KilterSessionStats.make(logs, 0, 10_000)
        assertEquals(listOf("Early", "Late"), s.timeline.map { it.climbName })
    }

    @Test fun emptySession() {
        val s = KilterSessionStats.make(emptyList(), 0, 1000)
        assertEquals(0, s.totalClimbs)
        assertTrue(s.pyramid.isEmpty())
        assertNull(s.hardestSendGrade)
        assertNull(s.hr)
    }
}
