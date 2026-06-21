package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the PURE persistence layer behind [KilterBoardMemoryStore] — [KilterBoardMemoryState].
 * The SharedPreferences/Context edge of the store is a thin uninjected wrapper; everything testable
 * (map↔JSON round-trip + the remember/confirm/rename/forget mutations + recall cross-check) lives in the
 * pure layer and runs on the JVM with a plain in-memory map. Mirrors `KilterBoardMemoryTests.swift`.
 */
class KilterBoardMemoryStoreTest {

    // ── remember (identity only) ───────────────────────────────────────────────

    @Test fun remember_createsBoard_withIdentity_noAngleHistory() {
        val map = KilterBoardMemoryState.remembering(
            emptyMap(), deviceId = "dev-1", layoutId = 1, sizeId = 10,
            label = null, serial = "S1", coarsePlace = null, lastSeen = 100,
        )
        val board = map["dev-1"]
        assertNotNull(board)
        assertEquals(1, board!!.layoutId)
        assertEquals(10, board.sizeId)
        assertEquals("S1", board.serial)
        assertEquals(100L, board.lastSeen)
        // A plain connect must NOT seed an angle — identity only.
        assertTrue(board.angleHistory.isEmpty())
        assertNull(board.usualAngle)
        // No explicit label → the rules' default ("Board <serial>").
        assertEquals("Board S1", board.label)
    }

    @Test fun remember_thenRecall_byDeviceId() {
        val map = KilterBoardMemoryState.remembering(
            emptyMap(), "dev-1", 2, 17, null, "S1", null, 100,
        )
        val recalled = KilterBoardMemoryRules.recall(map, deviceId = "dev-1")
        assertNotNull(recalled)
        assertEquals(2, recalled!!.layoutId)
        assertEquals(17, recalled.sizeId)
    }

    @Test fun remember_update_preservesAngleHistory_andLabel_andSerial_andPlace() {
        val place = CoarsePlace.bucket(52.123, 4.988)
        var map = KilterBoardMemoryState.remembering(
            emptyMap(), "dev-1", 1, 10, label = null, serial = "S1", coarsePlace = place, lastSeen = 100,
        )
        map = KilterBoardMemoryState.confirmingAngle(map, "dev-1", 40, lastSeen = 110)
        map = KilterBoardMemoryState.renaming(map, "dev-1", "8x12 Home")
        // A later identity update with no label / serial / place must not clobber what we already know,
        // and must never touch the angle history.
        map = KilterBoardMemoryState.remembering(
            map, "dev-1", layoutId = 3, sizeId = 12,
            label = null, serial = null, coarsePlace = null, lastSeen = 200,
        )
        val board = map["dev-1"]!!
        assertEquals(3, board.layoutId)             // updated
        assertEquals(12, board.sizeId)              // updated
        assertEquals(200L, board.lastSeen)          // updated
        assertEquals("8x12 Home", board.label)      // user rename preserved
        assertEquals("S1", board.serial)            // known serial preserved
        assertEquals(place, board.coarsePlace)      // known place preserved
        assertEquals(listOf(40), board.angleHistory) // history untouched by remember
    }

    @Test fun remember_explicitLabel_overridesDefault_butLaterNullKeepsIt() {
        var map = KilterBoardMemoryState.remembering(
            emptyMap(), "dev-1", 1, 10, label = "My Board", serial = "S1", coarsePlace = null, lastSeen = 100,
        )
        assertEquals("My Board", map["dev-1"]!!.label)
        map = KilterBoardMemoryState.remembering(map, "dev-1", 1, 10, null, "S1", null, 200)
        assertEquals("My Board", map["dev-1"]!!.label) // null label leaves the existing one alone
    }

    // ── confirmAngle (the ONLY path that grows history) ─────────────────────────

    @Test fun confirmAngle_appendsOnce_perCall() {
        var map = KilterBoardMemoryState.remembering(emptyMap(), "dev-1", 1, 10, null, null, null, 100)
        assertTrue(map["dev-1"]!!.angleHistory.isEmpty())
        map = KilterBoardMemoryState.confirmingAngle(map, "dev-1", 40, lastSeen = 110)
        assertEquals(listOf(40), map["dev-1"]!!.angleHistory)
        map = KilterBoardMemoryState.confirmingAngle(map, "dev-1", 25, lastSeen = 120)
        assertEquals(listOf(40, 25), map["dev-1"]!!.angleHistory)
        map = KilterBoardMemoryState.confirmingAngle(map, "dev-1", 40, lastSeen = 130)
        assertEquals(listOf(40, 25, 40), map["dev-1"]!!.angleHistory)
        assertEquals(130L, map["dev-1"]!!.lastSeen) // confirm bumps lastSeen
        assertEquals(40, map["dev-1"]!!.usualAngle)  // most-frequent via the rules
    }

    @Test fun confirmAngle_unknownDevice_isNoOp() {
        val before = KilterBoardMemoryState.remembering(emptyMap(), "dev-1", 1, 10, null, null, null, 100)
        val after = KilterBoardMemoryState.confirmingAngle(before, "ghost", 40, lastSeen = 200)
        assertEquals(before, after)
    }

    // ── rename / forget ─────────────────────────────────────────────────────────

    @Test fun rename_changesLabel_only() {
        var map = KilterBoardMemoryState.remembering(emptyMap(), "dev-1", 1, 10, null, "S1", null, 100)
        map = KilterBoardMemoryState.renaming(map, "dev-1", "Gym Board")
        assertEquals("Gym Board", map["dev-1"]!!.label)
        assertEquals("S1", map["dev-1"]!!.serial) // nothing else moved
    }

    @Test fun rename_unknownDevice_isNoOp() {
        val before = KilterBoardMemoryState.remembering(emptyMap(), "dev-1", 1, 10, null, null, null, 100)
        val after = KilterBoardMemoryState.renaming(before, "ghost", "X")
        assertEquals(before, after)
    }

    @Test fun forget_removesBoard_nextRecallMisses() {
        var map = KilterBoardMemoryState.remembering(emptyMap(), "dev-1", 1, 10, null, "S1", null, 100)
        assertNotNull(KilterBoardMemoryRules.recall(map, "dev-1"))
        map = KilterBoardMemoryState.forgetting(map, "dev-1")
        assertTrue(map.isEmpty())
        assertNull(KilterBoardMemoryRules.recall(map, "dev-1"))
    }

    @Test fun forget_unknownDevice_isNoOp() {
        val before = KilterBoardMemoryState.remembering(emptyMap(), "dev-1", 1, 10, null, null, null, 100)
        assertEquals(before, KilterBoardMemoryState.forgetting(before, "ghost"))
    }

    // ── serial cross-check (delegated to the rules) ─────────────────────────────

    @Test fun recall_serialCrossCheck_survivesReinstall() {
        // Old install learned the board under "old-id"; a reinstall mints "new-id" → direct miss, but the
        // serial still matches, so recall finds it via [KilterBoardMemoryRules.recall].
        val map = KilterBoardMemoryState.remembering(emptyMap(), "old-id", 1, 10, null, "S1", null, 100)
        assertNull(KilterBoardMemoryRules.recall(map, deviceId = "new-id"))            // no serial → miss
        val recalled = KilterBoardMemoryRules.recall(map, deviceId = "new-id", serial = "S1")
        assertNotNull(recalled)
        assertEquals("old-id", recalled!!.deviceId)
    }

    // ── sort order ──────────────────────────────────────────────────────────────

    @Test fun sortedByLastSeen_newestFirst() {
        var map = KilterBoardMemoryState.remembering(emptyMap(), "a", 1, 10, null, null, null, 100)
        map = KilterBoardMemoryState.remembering(map, "b", 1, 10, null, null, null, 300)
        map = KilterBoardMemoryState.remembering(map, "c", 1, 10, null, null, null, 200)
        assertEquals(listOf("b", "c", "a"), KilterBoardMemoryState.sortedByLastSeen(map).map { it.deviceId })
    }

    // ── JSON round-trip ─────────────────────────────────────────────────────────

    @Test fun json_roundTrip_preservesEverything_includingCoarsePlace() {
        val place = CoarsePlace.bucket(52.123456, 4.987654) // buckets to (52.123, 4.988)
        var map = KilterBoardMemoryState.remembering(
            emptyMap(), "dev-1", layoutId = 7, sizeId = 17,
            label = "Home", serial = "S1", coarsePlace = place, lastSeen = 100,
        )
        map = KilterBoardMemoryState.confirmingAngle(map, "dev-1", 40, lastSeen = 110)
        map = KilterBoardMemoryState.confirmingAngle(map, "dev-1", 25, lastSeen = 120)
        // A second board with no place / no serial to exercise the nullable fields.
        map = KilterBoardMemoryState.remembering(map, "dev-2", 1, 10, null, null, null, 50)

        val text = KilterBoardMemoryState.encode(map)
        val decoded = KilterBoardMemoryState.decode(text)

        assertEquals(map, decoded)
        val a = decoded["dev-1"]!!
        assertEquals(7, a.layoutId)
        assertEquals(17, a.sizeId)
        assertEquals("Home", a.label)
        assertEquals("S1", a.serial)
        assertEquals(listOf(40, 25), a.angleHistory)
        assertEquals(place, a.coarsePlace)                     // CoarsePlace survives via the surrogate
        assertEquals(52.123, a.coarsePlace!!.lat, 1e-9)
        assertEquals(4.988, a.coarsePlace!!.lon, 1e-9)
        val b = decoded["dev-2"]!!
        assertNull(b.serial)
        assertNull(b.coarsePlace)
        assertTrue(b.angleHistory.isEmpty())
    }

    @Test fun decode_nullOrBlankOrGarbage_yieldsEmptyMap() {
        assertTrue(KilterBoardMemoryState.decode(null).isEmpty())
        assertTrue(KilterBoardMemoryState.decode("").isEmpty())
        assertTrue(KilterBoardMemoryState.decode("   ").isEmpty())
        assertTrue(KilterBoardMemoryState.decode("not json {{{").isEmpty())
    }

    @Test fun encode_emptyMap_roundTripsToEmpty() {
        assertEquals(emptyMap<String, RememberedBoard>(), KilterBoardMemoryState.decode(KilterBoardMemoryState.encode(emptyMap())))
    }
}
