package com.snappet.mobile.feature.kilter.share

/**
 * Pure parser + builder for the cross-platform Kilter share link
 * `snappet://kilter/climb/<uuid>?angle=<n>`. Byte-compatible with the iOS `KilterDeepLink` so an
 * Android-rendered QR opens on iOS and an iOS QR opens on Android (issue #91). No Android deps →
 * fully JVM-unit-tested. The UUIDv5 content identity ([KilterClimbIdentity]) is what the `<uuid>`
 * encodes, so the same authored climb dedups across devices.
 */
object KilterDeepLink {

    const val SCHEME = "snappet"
    const val HOST = "kilter"

    /** A parsed `snappet://kilter/climb/<uuid>?angle=<n>` link. */
    data class ClimbLink(val uuid: String, val angle: Int?)

    /** Build the canonical share URL for a climb (angle optional). Lowercases the uuid. */
    fun climbUrl(uuid: String, angle: Int? = null): String {
        val base = "$SCHEME://$HOST/climb/${uuid.lowercase()}"
        return if (angle != null) "$base?angle=$angle" else base
    }

    /**
     * Parse a `snappet://kilter/climb/<uuid>` link, returning null for anything that isn't one.
     * Tolerant of a trailing slash, an `?angle=` query, and case in the scheme/host. The uuid is
     * validated to the 8-4-4-4-12 dashed-hex shape so junk text after a scan is rejected.
     */
    fun parse(raw: String): ClimbLink? {
        val s = raw.trim()
        // Split off the query first.
        val qIdx = s.indexOf('?')
        val path = if (qIdx >= 0) s.substring(0, qIdx) else s
        val query = if (qIdx >= 0) s.substring(qIdx + 1) else ""

        // Expect <scheme>://<host>/climb/<uuid>
        val sepIdx = path.indexOf("://")
        if (sepIdx < 0) return null
        val scheme = path.substring(0, sepIdx).lowercase()
        if (scheme != SCHEME) return null
        val rest = path.substring(sepIdx + 3).trimEnd('/')
        val parts = rest.split('/').filter { it.isNotEmpty() }
        // parts = [host, "climb", uuid]
        if (parts.size != 3) return null
        if (!parts[0].equals(HOST, ignoreCase = true)) return null
        if (!parts[1].equals("climb", ignoreCase = true)) return null
        val uuid = parts[2].lowercase()
        if (!isUuid(uuid)) return null

        val angle = parseQuery(query)["angle"]?.toIntOrNull()
        return ClimbLink(uuid = uuid, angle = angle)
    }

    private fun parseQuery(query: String): Map<String, String> =
        query.split('&').mapNotNull { pair ->
            if (pair.isEmpty()) return@mapNotNull null
            val eq = pair.indexOf('=')
            if (eq < 0) pair to "" else pair.substring(0, eq) to pair.substring(eq + 1)
        }.toMap()

    private val UUID_RE = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private fun isUuid(s: String): Boolean = UUID_RE.matches(s)
}
