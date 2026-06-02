package com.snappet.mobile.feature.kilter

/**
 * Encodes a climb's lit holds into the Aurora/Kilter board's BLE wire format. Mirrors the iOS
 * `KilterProtocol`.
 *
 * ⚠️ Community-reverse-engineered Aurora protocol, **not yet validated on physical hardware** — per
 * the repo's device-only rule, illumination must be confirmed on a real board before it's reported
 * as working. Kept as a pure object so the byte layout can be checked independently of the BLE stack.
 *
 * Wire format: each hold → 3 bytes (position uint16 LE + R3G3B2 color byte); the body is split into
 * <= [BODY_CHUNK] chunks, each prefixed with a packet-type marker and wrapped as
 * `[0x01, length, checksum, <marker + chunk...>, 0x02]` with `checksum = ~(sum) & 0xFF`.
 */
object KilterProtocol {
    // 15 body bytes = 5 holds (3 bytes each) per packet. Framed: 1 marker + 15 + 4 wrapper = 20 bytes,
    // i.e. the default BLE ATT payload — and holds never straddle a packet boundary.
    const val BODY_CHUNK = 15
    private const val PACKET_MIDDLE = 81
    private const val PACKET_FIRST = 82
    private const val PACKET_LAST = 83
    private const val PACKET_ONLY = 84

    fun colorByte(hex: String): Int {
        val (r, g, b) = rgb(hex)
        return ((r / 32) shl 5) or ((g / 32) shl 2) or (b / 64)
    }

    fun body(holds: List<Pair<Int, String>>): List<Int> {
        val out = ArrayList<Int>(holds.size * 3)
        for ((position, hex) in holds) {
            out.add(position and 0xFF)
            out.add((position shr 8) and 0xFF)
            out.add(colorByte(hex))
        }
        return out
    }

    /** Framed BLE messages to write, in order, to illuminate the holds (`position` to color hex). */
    fun messages(holds: List<Pair<Int, String>>): List<ByteArray> {
        val body = body(holds)
        if (body.isEmpty()) return listOf(wrap(listOf(PACKET_ONLY)))
        val chunks = body.chunked(BODY_CHUNK)
        if (chunks.size == 1) return listOf(wrap(listOf(PACKET_ONLY) + chunks[0]))
        return chunks.mapIndexed { index, chunk ->
            val marker = when (index) {
                0 -> PACKET_FIRST
                chunks.lastIndex -> PACKET_LAST
                else -> PACKET_MIDDLE
            }
            wrap(listOf(marker) + chunk)
        }
    }

    private fun wrap(payload: List<Int>): ByteArray {
        val bytes = ArrayList<Int>(payload.size + 4)
        bytes.add(0x01); bytes.add(payload.size); bytes.add(checksum(payload))
        bytes.addAll(payload); bytes.add(0x02)
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
