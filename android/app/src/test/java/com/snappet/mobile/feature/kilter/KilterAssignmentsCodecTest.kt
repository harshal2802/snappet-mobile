package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit coverage for the assignments saved-state codec (issue #86): the create-climb draft must
 * round-trip through the Bundle, and decode must tolerate unknown roles and malformed entries so a
 * stale saved draft can never fail the restore.
 */
class KilterAssignmentsCodecTest {

    @Test fun roundTripPreservesEveryAssignment() {
        val draft = mapOf(
            25 to KilterAuthorRole.FINISH, 1 to KilterAuthorRole.START,
            13 to KilterAuthorRole.MIDDLE, 7 to KilterAuthorRole.FOOT,
        )
        assertEquals(draft, decodeAssignments(encodeAssignments(draft)))
    }

    @Test fun roundTripEmptyMap() {
        assertTrue(decodeAssignments(encodeAssignments(emptyMap())).isEmpty())
    }

    @Test fun encodingIsSortedAndReadable() {
        assertEquals(arrayListOf("1:start", "13:middle", "25:finish"),
            encodeAssignments(mapOf(25 to KilterAuthorRole.FINISH, 1 to KilterAuthorRole.START, 13 to KilterAuthorRole.MIDDLE)))
    }

    @Test fun unknownRoleNamesAreDropped() {
        assertEquals(mapOf(1 to KilterAuthorRole.START),
            decodeAssignments(listOf("1:start", "2:legacyRole", "3:")))
    }

    @Test fun malformedEntriesAreDropped() {
        assertEquals(mapOf(4 to KilterAuthorRole.FOOT),
            decodeAssignments(listOf("nope", "x:start", ":start", "4:foot")))
    }
}
