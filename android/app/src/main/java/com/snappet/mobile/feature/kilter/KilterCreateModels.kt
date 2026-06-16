package com.snappet.mobile.feature.kilter

/**
 * A hold role the user can author — the four canonical Kilter roles, each carrying the **main-line** role
 * id used in `frames` (`p<placement>r<roleId>`), the same ids the generator emits and the catalog decodes
 * (12/13/14/15). Pure → unit-tested. Mirrors iOS `KilterAuthorRole`.
 */
enum class KilterAuthorRole(val roleId: Int, val roleName: String) {
    START(12, "start"),
    MIDDLE(13, "middle"),
    FINISH(14, "finish"),
    FOOT(15, "foot");

    /** Tap-to-cycle order: unset → start → middle → finish → foot → unset. */
    val next: KilterAuthorRole?
        get() = when (this) {
            START -> MIDDLE
            MIDDLE -> FINISH
            FINISH -> FOOT
            FOOT -> null   // back to unset
        }

    companion object {
        /** Decode a frames role id back to an author role (null for ids outside the four authorable roles). */
        fun fromRoleId(roleId: Int): KilterAuthorRole? = when (roleId) {
            12, 42 -> START
            13, 43 -> MIDDLE
            14, 44 -> FINISH
            15, 45 -> FOOT
            else -> null
        }
    }
}

/** Build a canonical (sorted) `frames` string from authored `placementId → role` assignments — stable
 *  regardless of tap order, feeding both the deterministic uuid and dedup. Pure. */
fun kilterFrames(assignments: Map<Int, KilterAuthorRole>): String =
    assignments.entries
        .map { it.key to it.value.roleId }
        .sortedWith(compareBy({ it.first }, { it.second }))
        .joinToString("") { "p${it.first}r${it.second}" }

/**
 * Issue #91: parse a pasted `p<placement>r<role>` frames string back into editor [KilterAuthorRole]
 * assignments. Pure (uses the shared [KilterCatalog.parseFrames]) → JVM-unit-tested. Roles that don't
 * map to an editor role (e.g. an unknown role id) are dropped; the last role for a placement wins.
 * [validPlacements], when non-null, filters to placements that exist on the target layout/size so a
 * frames string from another board can't inject off-board holds.
 */
fun parseFramesToAssignments(
    frames: String,
    validPlacements: Set<Int>? = null,
): Map<Int, KilterAuthorRole> {
    val out = LinkedHashMap<Int, KilterAuthorRole>()
    for ((placement, roleId) in KilterCatalog.parseFrames(frames)) {
        if (validPlacements != null && placement !in validPlacements) continue
        val role = KilterAuthorRole.fromRoleId(roleId) ?: continue
        out[placement] = role
    }
    return out
}

/** Why a draft climb isn't yet valid to save. Mirrors iOS `KilterClimbValidationError`. */
sealed class KilterClimbValidationError(val message: String) {
    data class TooFewHolds(val need: Int) : KilterClimbValidationError("Add at least $need holds.")
    data object MissingStart : KilterClimbValidationError("Mark at least one start hold.")
    data object MissingFinish : KilterClimbValidationError("Mark at least one finish hold.")
}

/** Validate an authored hold set — the generator's floor: ≥[minHolds], ≥1 start, ≥1 finish. `null` ⇒ savable. */
fun kilterValidate(assignments: Map<Int, KilterAuthorRole>, minHolds: Int = 4): KilterClimbValidationError? {
    val roles = assignments.values
    if (assignments.size < minHolds) return KilterClimbValidationError.TooFewHolds(minHolds)
    if (!roles.contains(KilterAuthorRole.START)) return KilterClimbValidationError.MissingStart
    if (!roles.contains(KilterAuthorRole.FINISH)) return KilterClimbValidationError.MissingFinish
    return null
}

/**
 * A tappable hole on the **authoring** board: a placement the user can assign a role to, normalized to the
 * same view space (x,y in 0…1, y from top) as [KilterHold] so editor targets line up with the grid and any
 * lit holds. Deduped to one placement per hole for a layout/size. Mirrors iOS `KilterPlaceableHold`.
 */
data class KilterPlaceableHold(
    val placementId: Int,
    val holeId: Int,
    val x: Double,
    val y: Double,
)
