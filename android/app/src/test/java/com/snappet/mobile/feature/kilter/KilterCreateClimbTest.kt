package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit coverage for authoring a climb (manual editor + generator share this core): content identity,
 * canonical frames, the save floor, role cycling, and duplicate detection. Mirrors iOS
 * `KilterCreateClimbTests` — crucially, the **same golden UUID vector**, proving an iPhone and an Android
 * phone that author the identical climb agree on its id.
 */
class KilterCreateClimbTest {

    // --- Canonicalization + identity ---

    @Test fun canonicalFramesIsOrderIndependent() {
        val a = KilterClimbIdentity.canonicalFrames("p25r14p1r12p13r13")
        val b = KilterClimbIdentity.canonicalFrames("p1r12p13r13p25r14")
        assertEquals(a, b)
        assertEquals("p1r12p13r13p25r14", a)
    }

    @Test fun uuidIsDeterministicAndOrderIndependent() {
        val u1 = KilterClimbIdentity.uuid(1, "p25r14p1r12p13r13")
        val u2 = KilterClimbIdentity.uuid(1, "p1r12p13r13p25r14")
        assertEquals(u1, u2)
    }

    /** Golden vector — MUST equal the iOS value (`KilterCreateClimbTests.testUUIDGoldenVector`), so the
     *  same climb on iOS and Android maps to one uuid. */
    @Test fun uuidGoldenVectorMatchesIOS() {
        assertEquals("d4e7b15e-a007-582c-8e1c-b143ddde0503",
            KilterClimbIdentity.uuid(1, "p1r12p13r13p25r14"))
    }

    @Test fun uuidIsLayoutScoped() {
        assertNotEquals(KilterClimbIdentity.uuid(1, "p1r12p13r13p25r14"),
            KilterClimbIdentity.uuid(2, "p1r12p13r13p25r14"))
    }

    @Test fun uuidHasVersion5AndRfcVariant() {
        val u = KilterClimbIdentity.uuid(1, "p1r12p13r13p25r14")
        assertEquals('5', u[14])
        assertTrue(u[19] in "89ab")
    }

    // --- Frames + roles + validation ---

    @Test fun framesFromAssignmentsIsCanonical() {
        val frames = kilterFrames(mapOf(13 to KilterAuthorRole.MIDDLE, 1 to KilterAuthorRole.START, 25 to KilterAuthorRole.FINISH))
        assertEquals("p1r12p13r13p25r14", frames)
    }

    @Test fun roleIdMappingAndRoundTrip() {
        assertEquals(12, KilterAuthorRole.START.roleId)
        assertEquals(15, KilterAuthorRole.FOOT.roleId)
        for (r in KilterAuthorRole.entries) assertEquals(r, KilterAuthorRole.fromRoleId(r.roleId))
        assertEquals(KilterAuthorRole.START, KilterAuthorRole.fromRoleId(42))
        assertNull(KilterAuthorRole.fromRoleId(99))
    }

    @Test fun roleCycleOrder() {
        assertEquals(KilterAuthorRole.MIDDLE, KilterAuthorRole.START.next)
        assertEquals(KilterAuthorRole.FINISH, KilterAuthorRole.MIDDLE.next)
        assertEquals(KilterAuthorRole.FOOT, KilterAuthorRole.FINISH.next)
        assertNull(KilterAuthorRole.FOOT.next)
    }

    @Test fun validationFloor() {
        assertEquals(KilterClimbValidationError.TooFewHolds(4), kilterValidate(emptyMap()))
        assertEquals(KilterClimbValidationError.MissingStart,
            kilterValidate(mapOf(1 to KilterAuthorRole.MIDDLE, 2 to KilterAuthorRole.MIDDLE, 3 to KilterAuthorRole.FINISH, 4 to KilterAuthorRole.FOOT)))
        assertEquals(KilterClimbValidationError.MissingFinish,
            kilterValidate(mapOf(1 to KilterAuthorRole.START, 2 to KilterAuthorRole.MIDDLE, 3 to KilterAuthorRole.MIDDLE, 4 to KilterAuthorRole.FOOT)))
        assertNull(kilterValidate(mapOf(1 to KilterAuthorRole.START, 2 to KilterAuthorRole.MIDDLE, 3 to KilterAuthorRole.FINISH, 4 to KilterAuthorRole.FOOT)))
    }

    // --- Duplicate detection ---

    private fun checker() = KilterDuplicateChecker(
        catalogRows = listOf(
            KilterDuplicateChecker.CatalogRow("cat-1", "Existing", "Setter", "p1r12p13r13p25r14"),
            KilterDuplicateChecker.CatalogRow("cat-2", "Other", "Setter", "p2r12p9r14"),
        ),
        createdClimbs = listOf(
            KilterDuplicateChecker.CreatedRow("mine-1", "My Climb", "You", 1, "p5r12p6r14p7r13p8r13"),
        ),
        layoutId = 1,
    )

    @Test fun duplicateMatchesCatalogRegardlessOfOrder() {
        val dup = checker().find(1, "p25r14p13r13p1r12")
        assertEquals("cat-1", dup?.uuid)
        assertEquals(KilterDuplicateChecker.Origin.CATALOG, dup?.origin)
    }

    @Test fun duplicateMatchesCreatedClimb() {
        val dup = checker().find(1, "p8r13p7r13p6r14p5r12")
        assertEquals("mine-1", dup?.uuid)
        assertEquals(KilterDuplicateChecker.Origin.CREATED, dup?.origin)
    }

    @Test fun noDuplicateForNewHolds() {
        assertNull(checker().find(1, "p100r12p101r14p102r13p103r13"))
    }

    @Test fun duplicateIsLayoutScoped() {
        assertNull(checker().find(2, "p1r12p13r13p25r14"))
    }

    @Test fun createdShadowsCatalogWithSameHolds() {
        val c = KilterDuplicateChecker(
            catalogRows = listOf(KilterDuplicateChecker.CatalogRow("cat", "Cat", "S", "p1r12p2r14p3r13p4r13")),
            createdClimbs = listOf(KilterDuplicateChecker.CreatedRow("mine", "Mine", "You", 1, "p1r12p2r14p3r13p4r13")),
            layoutId = 1,
        )
        assertEquals(KilterDuplicateChecker.Origin.CREATED, c.find(1, "p1r12p2r14p3r13p4r13")?.origin)
    }
}
