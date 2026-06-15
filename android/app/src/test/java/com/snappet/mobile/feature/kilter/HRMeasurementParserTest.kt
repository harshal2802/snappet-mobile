package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.hr.HRMeasurementParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure 0x2A37 parse parity with the iOS BLEHeartRateMetricsSource. */
class HRMeasurementParserTest {

    private fun bytes(vararg v: Int) = v.map { it.toByte() }.toByteArray()

    @Test fun uint8_simple() {
        // flags=0x00 (8-bit, no contact support), bpm=72.
        val m = HRMeasurementParser.parse(bytes(0x00, 72))!!
        assertEquals(72, m.bpm)
        assertNull(m.contact)         // contact unsupported → null, not false
        assertNull(m.rrIntervalsMs)
    }

    @Test fun uint16_value() {
        // flags=0x01 (16-bit), bpm = 300 = 0x012C little-endian.
        val m = HRMeasurementParser.parse(bytes(0x01, 0x2C, 0x01))!!
        assertEquals(300, m.bpm)
    }

    @Test fun contactStatus_supportedAndPresent() {
        // bit2 supported + bit1 status → contact true.
        assertEquals(true, HRMeasurementParser.parse(bytes(0x06, 80))!!.contact)
        // supported but no status bit → false (contact lost).
        assertEquals(false, HRMeasurementParser.parse(bytes(0x04, 80))!!.contact)
        // status bit set but NOT supported → null (gated by support).
        assertNull(HRMeasurementParser.parse(bytes(0x02, 80))!!.contact)
    }

    @Test fun rrIntervals_convertedToMs() {
        // flags=0x10 (RR present), one RR raw=1024 → 1000ms, one raw=512 → 500ms.
        val m = HRMeasurementParser.parse(bytes(0x10, 60, 0x00, 0x04, 0x00, 0x02))!!
        val rr = m.rrIntervalsMs!!
        assertEquals(2, rr.size)
        assertEquals(1000.0, rr[0], 1e-6)
        assertEquals(500.0, rr[1], 1e-6)
    }

    @Test fun energyExpended_isSkippedBeforeRR() {
        // flags = 0x10 | 0x08 (energy present + RR). bpm=60, energy=2 bytes, then RR raw=1024.
        val m = HRMeasurementParser.parse(bytes(0x18, 60, 0xFF, 0xFF, 0x00, 0x04))!!
        assertEquals(60, m.bpm)
        assertEquals(1000.0, m.rrIntervalsMs!!.single(), 1e-6)
    }

    @Test fun truncatedTrailingByte_isDropped() {
        // RR present, only one trailing byte after bpm → no whole interval.
        val m = HRMeasurementParser.parse(bytes(0x10, 60, 0x00))!!
        assertNull(m.rrIntervalsMs)
    }

    @Test fun malformed_returnsNull() {
        assertNull(HRMeasurementParser.parse(byteArrayOf()))
        assertNull(HRMeasurementParser.parse(bytes(0x01, 0x2C)))   // 16-bit flag but only 2 bytes
        assertNull(HRMeasurementParser.parse(bytes(0x00)))         // 8-bit flag but no value
    }

    @Test fun unsignedByteRead() {
        // bpm byte 0xC8 = 200, must read unsigned (not -56).
        assertEquals(200, HRMeasurementParser.parse(bytes(0x00, 0xC8))!!.bpm)
    }
}
