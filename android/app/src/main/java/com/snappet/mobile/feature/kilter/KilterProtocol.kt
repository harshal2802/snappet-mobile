package com.snappet.mobile.feature.kilter

/**
 * Encodes a climb's lit holds into the Aurora/Kilter board's BLE wire format. Mirrors the iOS
 * `KilterProtocol`.
 *
 * ⚠️ Community-reverse-engineered Aurora protocol, **not yet validated on physical hardware** — per
 * the repo's device-only rule, illumination must be confirmed on a real board before it's reported
 * as working. Kept as a pure object so the byte layout can be checked independently of the BLE stack.
 *
 * Wire format: each hold → 2 bytes (API level 2) or 3 bytes (API level 3) — position + packed color;
 * the body is split into <= [BODY_CHUNK] chunks, each prefixed with a packet-type marker and wrapped
 * as `[0x01, length, checksum, 0x02, <marker + chunk...>, 0x03]`, where `length`/`checksum` cover the
 * `<marker + chunk...>` packet data and `checksum = ~(sum) & 0xFF`.
 */
object KilterProtocol {
    /**
     * Which Aurora payload dialect to speak. The BLE link + UUIDs are identical across the family;
     * only the *payload* differs by board firmware generation, and it is **not negotiated** — the app
     * picks. [V3] (3-byte holds, R3G3B2) is what current boards use and the default; [V2] (2-byte
     * holds, R2G2B2) is for older controllers. A mismatch still connects fine but lights the wrong
     * holds/colors — hence the user-facing toggle.
     */
    enum class ApiLevel { V3, V2;
        /** Short control label. */
        val label: String get() = if (this == V3) "Standard" else "Legacy"
        /** Packet-type markers (first byte of packet data): first, middle, last, only. */
        internal val markers: IntArray get() = if (this == V3) intArrayOf(82, 81, 83, 84) else intArrayOf(78, 77, 79, 80)
        companion object {
            fun from(name: String?): ApiLevel = entries.firstOrNull { it.name == name } ?: V3
        }
    }

    // 12 is a multiple of both hold widths (2 and 3), and framed — 6 wrapper bytes
    // (0x01 len cksum 0x02 ... 0x03) + 1 marker + 12 body = 19 — fits the 20-byte BLE ATT payload,
    // so holds never straddle a packet boundary at either API level.
    const val BODY_CHUNK = 12

    /** Pack a hex color into the v3 R3G3B2 byte (bits 7-5 R, 4-2 G, 1-0 B). */
    fun colorByte(hex: String): Int {
        val (r, g, b) = rgb(hex)
        return ((r / 32) shl 5) or ((g / 32) shl 2) or (b / 64)
    }

    /** Pack a hex color into the v2 R2G2B2 bits in byte1 bits 7-2; bits 1-0 stay clear for position. */
    fun colorBitsV2(hex: String): Int {
        val (r, g, b) = rgb(hex)
        return ((r shr 6) shl 6) or ((g shr 6) shl 4) or ((b shr 6) shl 2)
    }

    fun body(holds: List<Pair<Int, String>>, level: ApiLevel = ApiLevel.V3): List<Int> {
        val out = ArrayList<Int>(holds.size * if (level == ApiLevel.V3) 3 else 2)
        for ((position, hex) in holds) {
            when (level) {
                ApiLevel.V3 -> {
                    out.add(position and 0xFF)
                    out.add((position shr 8) and 0xFF)
                    out.add(colorByte(hex))
                }
                ApiLevel.V2 -> {
                    out.add(position and 0xFF)
                    out.add(colorBitsV2(hex) or ((position shr 8) and 0x03))
                }
            }
        }
        return out
    }

    /** Framed BLE messages to write, in order, to illuminate the holds (`position` to color hex). */
    fun messages(holds: List<Pair<Int, String>>, level: ApiLevel = ApiLevel.V3): List<ByteArray> {
        val m = level.markers   // [first, middle, last, only]
        val body = body(holds, level)
        if (body.isEmpty()) return listOf(wrap(listOf(m[3])))
        val chunks = body.chunked(BODY_CHUNK)
        if (chunks.size == 1) return listOf(wrap(listOf(m[3]) + chunks[0]))
        return chunks.mapIndexed { index, chunk ->
            val marker = when (index) {
                0 -> m[0]
                chunks.lastIndex -> m[2]
                else -> m[1]
            }
            wrap(listOf(marker) + chunk)
        }
    }

    private fun wrap(payload: List<Int>): ByteArray {
        val bytes = ArrayList<Int>(payload.size + 5)
        bytes.add(0x01); bytes.add(payload.size); bytes.add(checksum(payload)); bytes.add(0x02)
        bytes.addAll(payload); bytes.add(0x03)
        return ByteArray(bytes.size) { (bytes[it] and 0xFF).toByte() }
    }

    private fun checksum(bytes: List<Int>): Int {
        var sum = 0
        for (b in bytes) sum = (sum + b) and 0xFF
        return sum.inv() and 0xFF
    }

    private fun rgb(hex: String): Triple<Int, Int, Int> {
        val v = hex.toLongOrNull(16) ?: 0xFFFFFFL
        return Triple(((v shr 16) and 0xFF).toInt(), ((v shr 8) and 0xFF).toInt(), (v and 0xFF).toInt())
    }
}
