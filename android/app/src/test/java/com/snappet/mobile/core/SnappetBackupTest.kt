package com.snappet.mobile.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The backup payload codec (issue #84): encode→decode must round-trip every SQLite
 * storage class bit-exactly, and validation must reject foreign/cross-version files
 * with readable messages — this is the contract the SAF export/import rides on.
 */
class SnappetBackupTest {

    private fun samplePayload() = SnappetBackup.Payload(
        formatVersion = SnappetBackup.FORMAT_VERSION,
        dbVersion = 4,
        exportedAtMillis = 1_770_000_000_000,
        tables = linkedMapOf(
            "journal_entries" to listOf(
                mapOf(
                    "id" to 1L, "title" to "Morning", "body" to "Climbed today.",
                    "tags" to "climbing,trip", "createdAt" to 1_769_000_000_000L,
                    "updatedAt" to 1_769_000_000_000L,
                ),
                mapOf(
                    "id" to 2L, "title" to "", "body" to "Quote: \"hello\" \n newline",
                    "tags" to "", "createdAt" to 1_769_100_000_000L,
                    "updatedAt" to 1_769_200_000_000L,
                ),
            ),
            "usage_records" to listOf(
                mapOf("id" to 9L, "module" to "tip", "action" to "calc",
                      "summary" to "Tipped", "metric" to 12.5, "timestamp" to 5L),
                mapOf("id" to 10L, "module" to "tip", "action" to "open",
                      "summary" to "Opened", "metric" to null, "timestamp" to 6L),
            ),
            "empty_table" to emptyList(),
        ),
    )

    @Test
    fun roundTripPreservesEveryStorageClass() {
        val original = samplePayload()
        val decoded = SnappetBackup.decode(SnappetBackup.encode(original))

        assertEquals(original.formatVersion, decoded.formatVersion)
        assertEquals(original.dbVersion, decoded.dbVersion)
        assertEquals(original.exportedAtMillis, decoded.exportedAtMillis)
        assertEquals(original.tables.keys, decoded.tables.keys)
        assertEquals(original.tables["journal_entries"], decoded.tables["journal_entries"])
        assertEquals(original.tables["usage_records"], decoded.tables["usage_records"])
        assertEquals(emptyList<Map<String, Any?>>(), decoded.tables["empty_table"])
        // Type fidelity, not just equality: INTEGER stays Long, REAL stays Double.
        assertTrue(decoded.tables["usage_records"]!![0]["id"] is Long)
        assertTrue(decoded.tables["usage_records"]!![0]["metric"] is Double)
        assertNull(decoded.tables["usage_records"]!![1]["metric"])
    }

    @Test
    fun blobsRideAsBase64() {
        val payload = SnappetBackup.Payload(
            SnappetBackup.FORMAT_VERSION, 4, 0,
            linkedMapOf("t" to listOf(mapOf("data" to byteArrayOf(0, 1, 2, 127, -128)))),
        )
        val decoded = SnappetBackup.decode(SnappetBackup.encode(payload))
        assertArrayEquals(byteArrayOf(0, 1, 2, 127, -128),
                          decoded.tables["t"]!![0]["data"] as ByteArray)
    }

    @Test
    fun decodeRejectsForeignFiles() {
        assertThrows(IllegalArgumentException::class.java) { SnappetBackup.decode("not json") }
        assertThrows(IllegalArgumentException::class.java) { SnappetBackup.decode("{}") }
        assertThrows(IllegalArgumentException::class.java) {
            SnappetBackup.decode("""{"formatVersion": 999, "dbVersion": 4, "tables": {}}""")
        }
    }

    @Test
    fun validateRejectsCrossVersionPayloads() {
        val older = samplePayload().copy(dbVersion = 3)
        val newer = samplePayload().copy(dbVersion = 9)
        val current = samplePayload()

        assertNull(SnappetBackup.validate(current, currentDbVersion = 4))
        assertNotNull(SnappetBackup.validate(older, currentDbVersion = 4))
        assertTrue(SnappetBackup.validate(older, 4)!!.contains("older"))
        assertTrue(SnappetBackup.validate(newer, 4)!!.contains("newer"))
        assertNotNull(SnappetBackup.validate(current.copy(tables = emptyMap()), 4))
    }
}
