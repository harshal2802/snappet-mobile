package com.snappet.mobile.feature.kilter.hr

/**
 * Pure parser for the standard BLE **Heart Rate Measurement** characteristic (`0x2A37`) of the
 * Heart Rate Profile (service `0x180D`). No Android / Bluetooth deps → unit-tested on the JVM.
 *
 * Ported byte-for-byte from the iOS `BLEHeartRateMetricsSource.parseMeasurement` so the two
 * platforms agree on the same wire format (HR value 8/16-bit, sensor-contact status, energy-expended
 * skip, RR-intervals in 1/1024 s). The kotlin gotcha is unsigned byte reads — [toInt] `and 0xFF`.
 */
object HRMeasurementParser {

    /**
     * One decoded measurement.
     * @property bpm beats per minute.
     * @property contact sensor-contact status: `true` = contact, `false` = lost, `null` = the band
     *   can't report contact (distinct from `false` — never drop samples on `null`).
     * @property rrIntervalsMs RR intervals in **milliseconds**, or `null` when absent.
     */
    data class Measurement(
        val bpm: Int,
        val contact: Boolean?,
        val rrIntervalsMs: List<Double>?,
    )

    // Flags byte (byte 0) bit masks — see the Bluetooth HR Measurement spec.
    private const val FLAG_VALUE_16BIT = 0x01    // bit 0: HR value is UInt16 (LE) instead of UInt8
    private const val FLAG_CONTACT_STATUS = 0x02 // bit 1: contact status (meaningful only if supported)
    private const val FLAG_CONTACT_SUPPORTED = 0x04 // bit 2: contact sensing supported
    private const val FLAG_ENERGY_PRESENT = 0x08 // bit 3: energy-expended UInt16 precedes RR
    private const val FLAG_RR_PRESENT = 0x10     // bit 4: RR-interval list (UInt16 LE, 1/1024 s each)

    /**
     * Decode a raw `0x2A37` payload, or return `null` if it is empty / too short to be valid.
     * A malformed packet must not poison the stream — the caller simply ignores `null`.
     */
    fun parse(data: ByteArray): Measurement? {
        if (data.isEmpty()) return null
        val flags = data[0].toInt() and 0xFF
        val isUInt16 = (flags and FLAG_VALUE_16BIT) != 0

        val bpm: Int
        var idx: Int
        if (isUInt16) {
            if (data.size < 3) return null            // flags + 2 value bytes
            bpm = (data[1].toInt() and 0xFF) or ((data[2].toInt() and 0xFF) shl 8)  // little-endian
            idx = 3
        } else {
            if (data.size < 2) return null
            bpm = data[1].toInt() and 0xFF
            idx = 2
        }

        // Energy-Expended (bit 3): a UInt16 that precedes RR. We don't use it (the HR Profile carries
        // no useful energy field for our purposes), but it must be stepped over.
        if ((flags and FLAG_ENERGY_PRESENT) != 0) idx += 2

        // RR-Intervals (bit 4): the rest of the buffer is UInt16 LE pairs in 1/1024 s → ms.
        var rr: List<Double>? = null
        if ((flags and FLAG_RR_PRESENT) != 0) {
            val out = ArrayList<Double>()
            while (idx + 1 < data.size) {              // strict <: only whole intervals, never past end
                val raw = (data[idx].toInt() and 0xFF) or ((data[idx + 1].toInt() and 0xFF) shl 8)
                out.add(raw * 1000.0 / 1024.0)         // 1/1024 s → ms; keep floating, don't truncate
                idx += 2
            }
            rr = if (out.isEmpty()) null else out
        }

        return Measurement(bpm = bpm, contact = contactStatus(flags), rrIntervalsMs = rr)
    }

    /**
     * Two independent bits (NOT a 2-bit enum): the *supported* bit is gated first — if unsupported,
     * status is unknown (`null`), never `false`. Mirrors iOS exactly.
     */
    fun contactStatus(flags: Int): Boolean? {
        val supported = (flags and FLAG_CONTACT_SUPPORTED) != 0
        if (!supported) return null
        return (flags and FLAG_CONTACT_STATUS) != 0
    }
}
