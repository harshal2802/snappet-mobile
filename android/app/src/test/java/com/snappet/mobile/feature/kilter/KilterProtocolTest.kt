package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit tests for the pure Aurora/Kilter "API level 3" wire encoder [KilterProtocol]. Mirrors the
 * iOS `KilterProtocolTests`: frame = `[0x01, len, checksum, 0x02, <marker + holds...>, 0x03]`, hold =
 * position uint16-LE + R3G3B2 color byte, <= 20 bytes per BLE write. Guards the framing fix that
 * resolved the "connected but unresponsive" board, off-device.
 */
class KilterProtocolTest {

    private fun ints(bytes: ByteArray) = bytes.map { it.toInt() and 0xFF }

    @Test
    fun colorBytePacksR3G3B2() {
        assertEquals(0x1C, KilterProtocol.colorByte("00FF00"))   // green
        assertEquals(0xE0, KilterProtocol.colorByte("FF0000"))   // red
        assertEquals(0x03, KilterProtocol.colorByte("0000FF"))   // blue
        assertEquals(0x00, KilterProtocol.colorByte("000000"))
        assertEquals(0xFF, KilterProtocol.colorByte("FFFFFF"))
    }

    @Test
    fun singleHoldFramesAsOnlyPacket() {
        // position 1096 = 0x0448 -> LE 0x48 0x04; color 00FF00 -> 0x1C; marker ONLY = 0x54.
        // checksum = ~(0x54+0x48+0x04+0x1C) & 0xFF = 0x43.
        val messages = KilterProtocol.messages(listOf(1096 to "00FF00"))
        assertEquals(1, messages.size)
        assertEquals(listOf(0x01, 0x04, 0x43, 0x02, 0x54, 0x48, 0x04, 0x1C, 0x03), ints(messages[0]))
    }

    @Test
    fun emptyHoldsClearsTheBoard() {
        val messages = KilterProtocol.messages(emptyList())
        assertEquals(listOf(0x01, 0x01, 0xAB, 0x02, 0x54, 0x03), ints(messages[0]))
    }

    @Test
    fun framingShapeAndChunkBoundaries() {
        // 5 holds = 15 body bytes > the 12-byte (4-hold) chunk -> FIRST(82) + LAST(83).
        val holds = (0 until 5).map { it to "00FF00" }
        val messages = KilterProtocol.messages(holds)

        assertEquals(2, messages.size)
        assertEquals(0x52, ints(messages[0])[4])               // first marker, after 0x01 len cksum 0x02
        assertEquals(0x53, ints(messages.last())[4])           // last marker
        for (message in messages) {
            val b = ints(message)
            assertEquals(0x01, b.first())
            assertEquals(0x03, b.last())
            assertTrue("each write must fit the 20-byte BLE ATT payload", b.size <= 20)
            assertEquals(b.size - 5, b[1])                      // length byte frames marker+holds payload
        }
    }
}
