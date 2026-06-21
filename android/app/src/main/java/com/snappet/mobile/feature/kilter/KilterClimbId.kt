package com.snappet.mobile.feature.kilter

/**
 * The single source of truth for the climb-uuid join/dedup key: trimmed + lowercased, so a created
 * climb's casing or stray whitespace can never split the same climb across rows. Every uuid-keyed Kilter
 * join normalizes through HERE, so the key can't drift between features (mirrors iOS `KilterClimbID`,
 * which itself unified the two byte-for-byte duplicate normalizers in On the Board + the gallery).
 *
 * P4/P5 Android ports reference this — it is defined exactly ONCE, here.
 */
object KilterClimbId {
    /** Canonical join key: trim surrounding whitespace/newlines, then lowercase. */
    fun normalize(uuid: String): String = uuid.trim().lowercase()
}
