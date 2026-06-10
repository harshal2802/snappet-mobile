package com.snappet.mobile.feature.kilter

/**
 * Pure codec between the create-climb draft (`placementId → role`) and its saved-instance-state
 * shape: an `ArrayList<String>` of `"placementId:roleName"` entries (e.g. `"123:start"`), sorted by
 * placement id for a stable encoding. Backs the `rememberSaveable` Saver in `CreateClimbScreen`
 * (issue #86). Pure → unit-tested.
 */
internal fun encodeAssignments(assignments: Map<Int, KilterAuthorRole>): ArrayList<String> =
    assignments.entries
        .sortedBy { it.key }
        .mapTo(ArrayList(assignments.size)) { "${it.key}:${it.value.roleName}" }

/** Inverse of [encodeAssignments]. Malformed entries and unknown role names are dropped — a stale
 *  saved draft degrades to "those holds are unset" instead of failing the restore. */
internal fun decodeAssignments(entries: List<String>): Map<Int, KilterAuthorRole> =
    entries.mapNotNull { entry ->
        val sep = entry.indexOf(':')
        if (sep <= 0) return@mapNotNull null
        val placementId = entry.substring(0, sep).toIntOrNull() ?: return@mapNotNull null
        val role = entry.substring(sep + 1)
        KilterAuthorRole.entries.firstOrNull { it.roleName == role }?.let { placementId to it }
    }.toMap()
