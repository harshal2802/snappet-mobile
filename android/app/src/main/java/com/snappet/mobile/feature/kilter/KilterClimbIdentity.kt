package com.snappet.mobile.feature.kilter

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * Deterministic, content-addressed identity for a climb the user *authors* on this device (manual editor
 * or the on-device generator). Pure (no Android deps) → unit-tested on the JVM, and **byte-for-byte
 * identical to the iOS `KilterClimbIdentity`** so the same climb authored on an iPhone and an Android phone
 * collapses to one uuid.
 *
 * A literal time-based UUID (v1/v7) can't be equal across devices (it embeds the clock + a node), so a
 * created climb's uuid is a **UUIDv5** (RFC 4122, SHA-1 namespaced) over the climb's *canonical* hold set.
 * Creation time is stored separately on [KilterCreatedClimb] — never folded into the identity. Two devices
 * generating the same climb therefore converge on one uuid → created climbs dedupe by uuid alone (catalog
 * climbs keep Aurora's random uuids, so those are matched by canonical frames — see [KilterDuplicateChecker]).
 */
object KilterClimbIdentity {
    /** Fixed namespace for Snappet-authored climbs. MUST match iOS (changing it re-keys every climb). */
    val NAMESPACE: UUID = UUID.fromString("5f6b9d2e-1c4a-4b7e-9f3c-8a2d6e1b0c44")

    /** Parse → sort `(placementId, roleId)` ascending → re-serialize: order-independent, so the same holds
     *  in any order yield the same string (the basis for the uuid and dedup). Uses the shared frame parser. */
    fun canonicalFrames(frames: String): String =
        KilterCatalog.parseFrames(frames)
            .sortedWith(compareBy({ it.first }, { it.second }))
            .joinToString("") { "p${it.first}r${it.second}" }

    /** Layout-scoped identity key `"<layoutId>:<canonicalFrames>"` — a placement id only means something
     *  within its layout (matches Aurora's `layout_id`+`frames` identity). */
    fun canonicalKey(layoutId: Int, frames: String): String = "$layoutId:${canonicalFrames(frames)}"

    /** The deterministic content uuid: UUIDv5 of the canonical key under the Snappet namespace. Same
     *  `(layout, holds)` → same uuid on every device. Lowercase dashed, matching the catalog's uuid shape. */
    fun uuid(layoutId: Int, frames: String): String =
        uuidV5(NAMESPACE, canonicalKey(layoutId, frames))

    /** RFC 4122 §4.3 name-based UUIDv5: SHA-1 over (namespace bytes ‖ name), first 16 bytes, with the
     *  version (5) + variant (RFC 4122) bits stamped in. */
    fun uuidV5(namespace: UUID, name: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        md.update(bytes(namespace))
        md.update(name.toByteArray(Charsets.UTF_8))
        val hash = md.digest()                  // 20 bytes
        val u = hash.copyOf(16)
        u[6] = ((u[6].toInt() and 0x0f) or 0x50).toByte()   // version 5
        u[8] = ((u[8].toInt() and 0x3f) or 0x80).toByte()   // variant 10xx
        return format(u)
    }

    /** The 16 raw bytes of a UUID (big-endian: most-significant first), matching iOS's `uuid` tuple order. */
    private fun bytes(uuid: UUID): ByteArray =
        ByteBuffer.allocate(16).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()

    /** Lowercase 8-4-4-4-12 hex. */
    private fun format(b: ByteArray): String {
        val hex = b.joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-" +
            "${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }
}
