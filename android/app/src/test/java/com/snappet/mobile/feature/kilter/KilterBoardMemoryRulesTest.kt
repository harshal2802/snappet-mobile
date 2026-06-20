package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KilterBoardMemoryRulesTest {

    private fun board(
        deviceId: String,
        serial: String? = null,
        lastSeen: Long,
        angleHistory: List<Int> = emptyList(),
        coarsePlace: CoarsePlace? = null,
    ) = RememberedBoard(
        deviceId = deviceId, serial = serial, layoutId = 1, sizeId = 10,
        angleHistory = angleHistory, label = "L", coarsePlace = coarsePlace, lastSeen = lastSeen,
    )

    // ── serialFromLocalName ────────────────────────────────────────────────────

    @Test fun serial_parsesNameHashSerialAtApi() {
        assertEquals("A1B2C3", KilterBoardMemoryRules.serialFromLocalName("Kilter#A1B2C3@3"))
    }

    @Test fun serial_noHash_returnsNull() {
        assertNull(KilterBoardMemoryRules.serialFromLocalName("Kilter A1B2C3"))
    }

    @Test fun serial_noAt_takesRestOfString() {
        assertEquals("A1B2C3", KilterBoardMemoryRules.serialFromLocalName("Kilter#A1B2C3"))
    }

    @Test fun serial_emptyName_returnsNull() {
        assertNull(KilterBoardMemoryRules.serialFromLocalName(""))
    }

    @Test fun serial_nullName_returnsNull() {
        assertNull(KilterBoardMemoryRules.serialFromLocalName(null))
    }

    @Test fun serial_emptySegment_returnsNull() {
        assertNull(KilterBoardMemoryRules.serialFromLocalName("Kilter#@3"))   // nothing between # and @
        assertNull(KilterBoardMemoryRules.serialFromLocalName("Kilter#  @3")) // whitespace-only
    }

    @Test fun serial_multipleHash_firstDelimitsThenRunsToAt() {
        // First '#' delimits the serial; it runs up to the first '@', so a later '#' is part of the serial.
        assertEquals("AB#CD", KilterBoardMemoryRules.serialFromLocalName("Kilter#AB#CD@3"))
    }

    // ── mostFrequentAngle ──────────────────────────────────────────────────────

    @Test fun mostFrequentAngle_picksMostCommon() {
        assertEquals(40, KilterBoardMemoryRules.mostFrequentAngle(listOf(40, 25, 40, 40, 25)))
    }

    @Test fun mostFrequentAngle_tie_breaksTowardMostRecent() {
        // 25 and 40 each appear twice; 40 appears latest in history, so it wins.
        assertEquals(40, KilterBoardMemoryRules.mostFrequentAngle(listOf(25, 40, 25, 40)))
        // Reverse the recency: now 25 is latest of the tied pair.
        assertEquals(25, KilterBoardMemoryRules.mostFrequentAngle(listOf(40, 25, 40, 25)))
    }

    @Test fun mostFrequentAngle_empty_returnsNull() {
        assertNull(KilterBoardMemoryRules.mostFrequentAngle(emptyList()))
    }

    @Test fun mostFrequentAngle_single() {
        assertEquals(30, KilterBoardMemoryRules.mostFrequentAngle(listOf(30)))
    }

    @Test fun usualAngle_readsHistory() {
        assertEquals(40, board("d", lastSeen = 1, angleHistory = listOf(40, 25, 40)).usualAngle)
        assertNull(board("d", lastSeen = 1).usualAngle)
    }

    // ── recall ─────────────────────────────────────────────────────────────────

    @Test fun recall_byDeviceId_direct() {
        val target = board("dev-1", serial = "S1", lastSeen = 100)
        val map = mapOf("dev-1" to target, "dev-2" to board("dev-2", serial = "S2", lastSeen = 200))
        assertEquals(target, KilterBoardMemoryRules.recall(map, deviceId = "dev-1"))
    }

    @Test fun recall_deviceIdWins_overSerial() {
        // Even if a serial is supplied, a direct deviceId hit takes precedence.
        val direct = board("dev-1", serial = "OTHER", lastSeen = 50)
        val map = mapOf(
            "dev-1" to direct,
            "dev-2" to board("dev-2", serial = "S1", lastSeen = 999),
        )
        assertEquals(direct, KilterBoardMemoryRules.recall(map, deviceId = "dev-1", serial = "S1"))
    }

    @Test fun recall_serialCrossCheck_returnsMostRecent() {
        // Fresh deviceId after a reinstall misses directly; two entries share the serial → newest wins.
        val older = board("old-id", serial = "S1", lastSeen = 100)
        val newer = board("older-id", serial = "S1", lastSeen = 500)
        val map = mapOf("old-id" to older, "older-id" to newer)
        val recalled = KilterBoardMemoryRules.recall(map, deviceId = "brand-new-id", serial = "S1")
        assertEquals(newer, recalled)
        assertEquals(500L, recalled?.lastSeen)
    }

    @Test fun recall_serialCrossCheck_noMatch_returnsNull() {
        val map = mapOf("dev-1" to board("dev-1", serial = "S1", lastSeen = 100))
        assertNull(KilterBoardMemoryRules.recall(map, deviceId = "new-id", serial = "NOPE"))
    }

    @Test fun recall_unknownDeviceId_noSerial_returnsNull() {
        val map = mapOf("dev-1" to board("dev-1", serial = "S1", lastSeen = 100))
        assertNull(KilterBoardMemoryRules.recall(map, deviceId = "ghost"))
    }

    @Test fun recall_emptyMap_returnsNull() {
        assertNull(KilterBoardMemoryRules.recall(emptyMap(), deviceId = "x", serial = "S1"))
    }

    // ── CoarsePlace + suggestion ───────────────────────────────────────────────

    @Test fun coarsePlace_buckets_andMatches() {
        // Two precise fixes clearly within the same ~110m square (both round to 52.123, 4.988 —
        // chosen away from the .0005 bucket boundary so they don't fall into adjacent squares).
        val a = CoarsePlace.bucket(52.123456, 4.987654)
        val b = CoarsePlace.bucket(52.123111, 4.987812)
        assertTrue(a.matches(b))
        assertEquals(52.123, a.lat, 1e-9)
        assertEquals(4.988, a.lon, 1e-9)
        assertEquals(52.123, b.lat, 1e-9)
        assertEquals(4.988, b.lon, 1e-9)
    }

    @Test fun coarsePlace_noMatch_differentSquare() {
        val gym = CoarsePlace.bucket(52.123, 4.988)
        val elsewhere = CoarsePlace.bucket(52.456, 4.988)
        assertFalse(gym.matches(elsewhere))
    }

    @Test fun suggestion_picksMostRecentInSameSquare() {
        val place = CoarsePlace.bucket(52.123, 4.988)
        val here = CoarsePlace.bucket(52.123, 4.988)
        val older = board("a", lastSeen = 100, coarsePlace = here)
        val newer = board("b", lastSeen = 500, coarsePlace = here)
        val faraway = board("c", lastSeen = 9999, coarsePlace = CoarsePlace.bucket(0.0, 0.0))
        val pick = KilterBoardMemoryRules.suggestion(place, listOf(older, newer, faraway))
        assertEquals(newer, pick)
    }

    @Test fun suggestion_noMatch_returnsNull() {
        val place = CoarsePlace.bucket(52.123, 4.988)
        val faraway = board("c", lastSeen = 9999, coarsePlace = CoarsePlace.bucket(0.0, 0.0))
        val noPlace = board("d", lastSeen = 1, coarsePlace = null)
        assertNull(KilterBoardMemoryRules.suggestion(place, listOf(faraway, noPlace)))
    }

    // ── defaultLabel ───────────────────────────────────────────────────────────

    @Test fun defaultLabel_usesSerialWhenKnown() {
        assertEquals("Board A1B2C3", KilterBoardMemoryRules.defaultLabel("Kilter Original", "A1B2C3"))
    }

    @Test fun defaultLabel_fallsBackWhenNoSerial() {
        assertEquals("Kilter board", KilterBoardMemoryRules.defaultLabel("Kilter Original", null))
        assertEquals("Kilter board", KilterBoardMemoryRules.defaultLabel(null, ""))
    }
}
