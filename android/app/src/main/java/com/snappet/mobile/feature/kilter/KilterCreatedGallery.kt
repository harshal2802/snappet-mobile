package com.snappet.mobile.feature.kilter

/**
 * The **pure** query/sort/filter + own-status-join engine behind the "Your Climbs" gallery (P2). Ported
 * from the iOS `KilterCreatedGallery`. No Room / Compose / catalog deps — it reasons over plain value
 * snapshots ([CreatedRow] / [LogRow]) that the renderer builds from its DB rows, so the whole "which of my
 * climbs show, in what order, with what status" decision runs in plain JVM unit tests against hand-built
 * rows (the same discipline [KilterSessionStats] follows).
 *
 * Unlike the old layout-scoped "Mine" filter, this is **global across layouts** — a climb you set on
 * another board still appears here. Layout is a *facet* you can filter by, never an implicit gate.
 */
object KilterCreatedGallery {

    // region Inputs

    /**
     * A device-free snapshot of one [KilterCreatedClimb] (the only fields the gallery reasons about).
     * The renderer builds these from its DB rows so the engine never touches Room.
     *
     * @property setterUsername the author's display name; searched alongside [name], restoring the legacy
     *   Mine filter's name-OR-setter match.
     * @property source `"manual"` or `"generated"`.
     * @property isValid `false` when frame validation failed for this climb's holds — a **Draft** (see
     *   [Segment.DRAFTS]). Derived by the renderer from the holds (no schema field), defaulting valid.
     * @property createdAt epoch millis.
     */
    data class CreatedRow(
        val uuid: String,
        val name: String,
        val setterUsername: String = "",
        val layoutId: Int,
        val angle: Int,
        val predictedGrade: Double?,
        val source: String,
        val isValid: Boolean = true,
        val createdAt: Long,
    )

    /**
     * A device-free snapshot of one [KilterLogEntry] the gallery needs to compute the user's OWN status.
     * Only the climb id + ascent status matter here — never community signals (none exist on-device).
     */
    data class LogRow(
        val climbUuid: String,
        val status: KilterAscentStatus,
    )

    // endregion

    // region Facets

    /**
     * The Draft / Saved / All status segment over the gallery. **Saved** here means a *savable* climb —
     * a complete, valid created climb (the opposite of a Draft), NOT the catalog "favorited" Saved filter.
     */
    enum class Segment(val label: String) {
        ALL("All"), SAVED("Saved"), DRAFTS("Drafts");
    }

    /**
     * How a created climb resolved against the user's OWN logbook — the per-card status chip. Derived
     * purely from the user's [KilterLogEntry] rows; there are no community ascents on-device, by design.
     */
    enum class OwnStatus(val label: String) {
        SENT("Sent"), PROJECT("Project"), ATTEMPT("Attempt"), UNTRIED("Untried");
    }

    /** Provenance — how the climb came to be (the per-card glyph + label). Mirrors the `source` column. */
    enum class Provenance(val label: String) {
        HAND_SET("Hand-set"), GENERATED("Generated");

        companion object {
            fun from(source: String): Provenance = if (source == "generated") GENERATED else HAND_SET
        }
    }

    /** Gallery sort order (the sort chip). */
    enum class Sort(val label: String) {
        /** Newest first (default) — by `createdAt`. */
        RECENT("Recently set"),
        /** Hardest first — by predicted/chosen grade (ungraded sinks last). */
        GRADE("Grade"),
        /** Most climbed by you — by own SEND count (sent + flash), then recency. (Attempts don't rank.) */
        MOST_CLIMBED("Most climbed");
    }

    // endregion

    // region Output

    /** One display row the gallery renders — the joined created climb + its own-logbook status + counts. */
    data class Item(
        val uuid: String,
        val name: String,
        val layoutId: Int,
        val angle: Int,
        val predictedGrade: Double?,
        val provenance: Provenance,
        val isDraft: Boolean,
        val ownStatus: OwnStatus,
        /** How many times the user has logged this climb (any status) — drives the displayed count. */
        val logCount: Int,
        /**
         * How many of those logs were SENDS (sent + flash) — the rank key for "Most climbed", so a
         * never-sent climb with many attempts can't outrank a real send.
         */
        val sendCount: Int,
        val createdAt: Long,
    )

    // endregion

    // region Engine

    /**
     * The DISTINCT angles present in the user's created climbs, ascending. The gallery is global across
     * layouts, so the angle facet must come from the climbs themselves — not the installed catalog — or a
     * climb authored at an off-catalog angle would be unreachable and the menu could offer empty-result
     * angles. Pure; the renderer feeds it the same [CreatedRow] snapshots.
     */
    fun angleFacets(created: List<CreatedRow>): List<Int> =
        created.map { it.angle }.toSortedSet().toList()

    /**
     * Resolve the user's OWN status for one climb from its log rows (already filtered to this uuid).
     * Explicit + future-proof precedence: any send/flash → **Sent**; else any [KilterAscentStatus.PROJECT]
     * → **Project**; else any [KilterAscentStatus.ATTEMPT] → **Attempt**; else (nothing logged) →
     * **Untried**. Listing the cases out (vs "non-empty && not-send => project") keeps a new
     * [KilterAscentStatus] case from silently bucketing. Pure; mirrors the detail screen's logbook reading
     * (never community data).
     */
    fun ownStatus(logs: List<LogRow>): OwnStatus = when {
        logs.any { it.status.isSend } -> OwnStatus.SENT
        logs.any { it.status == KilterAscentStatus.PROJECT } -> OwnStatus.PROJECT
        logs.any { it.status == KilterAscentStatus.ATTEMPT } -> OwnStatus.ATTEMPT
        else -> OwnStatus.UNTRIED
    }

    /**
     * The single source of truth for "which of my climbs show, in what order, with what status."
     *
     * @param created every created climb (global, all layouts).
     * @param logs the user's log entries (joined by [LogRow.climbUuid] for own-status + count).
     * @param segment Draft / Saved / All.
     * @param sort the sort order (default [Sort.RECENT]).
     * @param search free-text filter over name OR setter (case-insensitive, trimmed; empty = no filter).
     * @param layoutId when non-null, restrict to that layout (the optional board/layout facet — **off** by
     *   default, which is the global view); null = all layouts.
     * @param angle when non-null, restrict to climbs designed at that angle; null = any angle.
     * @param source when non-null, restrict to `"manual"` / `"generated"`; null = any source.
     * @return the ordered display items.
     */
    fun items(
        created: List<CreatedRow>,
        logs: List<LogRow>,
        segment: Segment = Segment.ALL,
        sort: Sort = Sort.RECENT,
        search: String = "",
        layoutId: Int? = null,
        angle: Int? = null,
        source: String? = null,
    ): List<Item> {
        // Index logs by climb once (O(logs)), so the join is O(created) lookups, not O(created*logs).
        // Normalize BOTH sides of the join (trim + lowercased) so a sent climb whose log uuid differs only
        // in case/whitespace still resolves — never silently shows Untried.
        val logsByClimb: Map<String, List<LogRow>> =
            logs.groupBy { KilterClimbId.normalize(it.climbUuid) }

        val term = search.trim().lowercase()

        val filtered = created.filter { row ->
            if (layoutId != null && row.layoutId != layoutId) return@filter false
            if (angle != null && row.angle != angle) return@filter false
            if (source != null && row.source != source) return@filter false
            when (segment) {
                Segment.ALL -> Unit
                Segment.SAVED -> if (!row.isValid) return@filter false
                Segment.DRAFTS -> if (row.isValid) return@filter false
            }
            // Search matches name OR setter (legacy Mine filter parity), case-insensitive + trimmed.
            if (term.isNotEmpty() &&
                !row.name.lowercase().contains(term) &&
                !row.setterUsername.lowercase().contains(term)
            ) {
                return@filter false
            }
            true
        }

        val mapped = filtered.map { row ->
            val rowLogs = logsByClimb[KilterClimbId.normalize(row.uuid)].orEmpty()
            Item(
                uuid = row.uuid,
                name = row.name,
                layoutId = row.layoutId,
                angle = row.angle,
                predictedGrade = row.predictedGrade,
                provenance = Provenance.from(row.source),
                isDraft = !row.isValid,
                ownStatus = ownStatus(rowLogs),
                logCount = rowLogs.size,
                sendCount = rowLogs.count { it.status.isSend },
                createdAt = row.createdAt,
            )
        }

        return sorted(mapped, sort)
    }

    /**
     * Stable sort for the gallery. Ties always break to **newest-first** so the order is deterministic
     * (two ungraded climbs, or two equally-climbed ones, fall back to recency).
     */
    fun sorted(items: List<Item>, sort: Sort): List<Item> = when (sort) {
        Sort.RECENT ->
            items.sortedByDescending { it.createdAt }

        Sort.GRADE ->
            // Hardest first; ungraded (null) sinks below every graded climb, then recency.
            items.sortedWith(
                // Graded before ungraded; within graded, higher grade first; ties → newest first.
                compareByDescending<Item> { it.predictedGrade != null }
                    .thenByDescending { it.predictedGrade ?: Double.NEGATIVE_INFINITY }
                    .thenByDescending { it.createdAt }
            )

        Sort.MOST_CLIMBED ->
            // Rank by the user's SEND count (sent + flash), not every log row — a never-sent climb with
            // many attempts must NOT outrank a sent one. Deterministic tie-break: then newest-first.
            items.sortedWith(
                compareByDescending<Item> { it.sendCount }.thenByDescending { it.createdAt }
            )
    }

    // endregion
}
