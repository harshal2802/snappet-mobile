package com.snappet.mobile.feature.kilter

/**
 * Validates a freshly-authored climb (manual *or* generated) against everything already on the device
 * before it's saved — same brief as iOS: dedupe against the downloaded dataset *and* prior creations.
 *
 * Duplicate ≡ same **canonical** hold set on the same layout ([KilterClimbIdentity.canonicalKey]), so the
 * match is order-independent. The index covers the read-only catalog (matched by canonical frames, since
 * catalog climbs carry Aurora's random uuids) and the user's created climbs (which carry the deterministic
 * content uuid). Layout-scoped. Pure core ([find]) is unit-tested; [build] reads the installed catalog.
 * Mirrors iOS `KilterDuplicateChecker`.
 */
class KilterDuplicateChecker(
    catalogRows: List<CatalogRow>,
    createdClimbs: List<CreatedRow>,
    private val layoutId: Int,
) {
    /** Where a duplicate came from. */
    enum class Origin { CATALOG, CREATED }

    data class Duplicate(val uuid: String, val name: String, val setter: String, val origin: Origin)
    data class CatalogRow(val uuid: String, val name: String, val setter: String, val frames: String)
    data class CreatedRow(val uuid: String, val name: String, val setter: String, val layoutId: Int, val frames: String)

    private val index: Map<String, Duplicate> = buildMap {
        for (r in catalogRows) {
            val key = KilterClimbIdentity.canonicalKey(layoutId, r.frames)
            if (!containsKey(key)) put(key, Duplicate(r.uuid, r.name, r.setter, Origin.CATALOG))
        }
        for (c in createdClimbs) if (c.layoutId == layoutId) {
            val key = KilterClimbIdentity.canonicalKey(layoutId, c.frames)
            put(key, Duplicate(c.uuid, c.name, c.setter, Origin.CREATED))   // created shadows catalog
        }
    }

    /** The existing climb this `(layout, frames)` duplicates, or null if new. Frames need not be canonical. */
    fun find(layoutId: Int, frames: String): Duplicate? {
        if (layoutId != this.layoutId) return null
        return index[KilterClimbIdentity.canonicalKey(layoutId, frames)]
    }

    companion object {
        /** Build a checker for one layout from the installed catalog + the user's created climbs. */
        fun build(layoutId: Int, catalog: KilterCatalog, created: List<KilterCreatedClimb>): KilterDuplicateChecker {
            val rows = catalog.climbFramesForDedup(layoutId)
            val createdRows = created.map {
                CreatedRow(it.uuid, it.name, it.setterUsername, it.layoutId, it.frames)
            }
            return KilterDuplicateChecker(rows, createdRows, layoutId)
        }
    }
}
