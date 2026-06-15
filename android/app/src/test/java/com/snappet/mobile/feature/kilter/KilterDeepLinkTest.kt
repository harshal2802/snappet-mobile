package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.hr.BleHeartRateSource
import com.snappet.mobile.feature.kilter.share.KilterDeepLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KilterDeepLinkTest {

    private val uuid = "5f6b9d2e-1c4a-4b7e-9f3c-8a2d6e1b0c44"

    @Test fun buildUrl_withAndWithoutAngle() {
        assertEquals("snappet://kilter/climb/$uuid", KilterDeepLink.climbUrl(uuid))
        assertEquals("snappet://kilter/climb/$uuid?angle=40", KilterDeepLink.climbUrl(uuid, 40))
    }

    @Test fun parse_roundTrip() {
        val link = KilterDeepLink.parse("snappet://kilter/climb/$uuid?angle=40")!!
        assertEquals(uuid, link.uuid)
        assertEquals(40, link.angle)
    }

    @Test fun parse_noAngle() {
        val link = KilterDeepLink.parse("snappet://kilter/climb/$uuid")!!
        assertEquals(uuid, link.uuid)
        assertNull(link.angle)
    }

    @Test fun parse_tolerantOfCaseAndTrailingSlash() {
        val link = KilterDeepLink.parse("SNAPPET://Kilter/climb/${uuid.uppercase()}/")!!
        assertEquals(uuid, link.uuid)   // lowercased
    }

    @Test fun parse_rejectsJunk() {
        assertNull(KilterDeepLink.parse("https://example.com"))
        assertNull(KilterDeepLink.parse("snappet://kilter/climb/not-a-uuid"))
        assertNull(KilterDeepLink.parse("snappet://kilter/other/$uuid"))
        assertNull(KilterDeepLink.parse("random text"))
    }

    @Test fun pasteFrames_roundTripsAssignments() {
        // p1r12 (start), p2r13 (middle), p3r14 (finish).
        val assignments = parseFramesToAssignments("p1r12p2r13p3r14")
        assertEquals(KilterAuthorRole.START, assignments[1])
        assertEquals(KilterAuthorRole.MIDDLE, assignments[2])
        assertEquals(KilterAuthorRole.FINISH, assignments[3])
        // Re-serializing yields a canonical frames string.
        assertEquals("p1r12p2r13p3r14", kilterFrames(assignments))
    }

    @Test fun pasteFrames_filtersOffBoardPlacements() {
        val assignments = parseFramesToAssignments("p1r12p999r14", validPlacements = setOf(1))
        assertEquals(setOf(1), assignments.keys)   // p999 dropped — not on this board
    }

    @Test fun rrTrust_defaultDeny_blacklistFirst() {
        // Chest straps trusted.
        assertTrue(BleHeartRateSource.rrTrusted("Polar H10", "Polar H10 1234"))
        assertTrue(BleHeartRateSource.rrTrusted("", "TICKR 6A2B"))
        // Optical rejected even if a whitelist token also matches ("TICKR FIT" is optical).
        assertFalse(BleHeartRateSource.rrTrusted("", "TICKR FIT 99"))
        assertFalse(BleHeartRateSource.rrTrusted("", "Polar OH1"))
        assertFalse(BleHeartRateSource.rrTrusted("", "Apple Watch"))
        // Unknown → deny.
        assertFalse(BleHeartRateSource.rrTrusted("", ""))
        assertFalse(BleHeartRateSource.rrTrusted("", "Mystery Strap"))
    }
}
