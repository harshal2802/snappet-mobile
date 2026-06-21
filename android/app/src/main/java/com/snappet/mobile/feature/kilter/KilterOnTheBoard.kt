package com.snappet.mobile.feature.kilter

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Pure, device-free logic behind **On the Board** (Kilter Improvement P5) — the history of every climb the
 * user *lit on the board*, including the ones pulled up and worked but never formally logged as an ascent.
 * No Room / Compose / Android-UI deps (only `java.time` for day bucketing + relative-day labels), so the
 * dedup, the day/session grouping + roll-ups, the status join, and the recent-rail ordering all run in plain
 * JVM unit tests with no device. Ported from the iOS `KilterOnTheBoard`.
 *
 * Views build [LitEvent] + [LogRow] value lists from their Room rows and read the result. The new
 * `KilterLitEvent` Room entity + persistence is a LATER wave — here [LitEvent] is a plain value type for the
 * engine/tests only.
 *
 * **Kilter-board data only.** Deterministic for a given input + clock.
 */
object KilterOnTheBoard {

    // MARK: - Input value types (plain mirrors of the Room rows)

    /**
     * One lit-on-the-board event, reduced to what On the Board needs (a value mirror of the future
     * `KilterLitEvent` Room row), so the pure logic never touches a Room entity. `litAt` is epoch millis.
     * [id] is a stable composite of the dedup key + the light time, so a row's UI identity survives a
     * re-query without needing a separate id column.
     */
    data class LitEvent(
        val climbUuid: String,
        val climbName: String,
        val gradeLabel: String,
        val angle: Int,
        val layoutId: Int,
        val sizeId: Int,
        /** Epoch millis. */
        val litAt: Long,
        val wasConnected: Boolean,
        /** [KilterSession.id] when lit during a session; null for out-of-session lights. */
        val sessionId: String? = null,
    ) {
        /**
         * Stable composite identity: normalized climb + session + light instant. Unique within the deduped
         * set (one row per climb-per-session), and identical across re-queries of the same data.
         */
        val id: String
            get() = "${normalizedUuid(climbUuid)}|${sessionId ?: "none"}|$litAt"
    }

    /**
     * One ascent-log row reduced to what the status join needs (a value mirror of [KilterLogEntry]). The
     * renderer adapts Room rows into these; tests synthesize them directly.
     */
    data class LogRow(
        val climbUuid: String,
        val status: KilterAscentStatus,
    ) {
        val isSend: Boolean get() = status.isSend
    }

    // MARK: - Joined status

    /** The status a lit climb resolves to once joined with the ascent log — the label the row's chip shows. */
    enum class Status(val label: String) {
        /** Lit but never logged (or only ever marked a project — still "in progress on the wall"). */
        LIT("Lit"),
        /** Tried (one or more `ATTEMPT` logs) but not sent. */
        ATTEMPT("Attempt"),
        /** Sent or flashed. */
        SENT("Sent"),
    }

    // MARK: - Display model

    /**
     * One row in the timeline: a deduped lit event with its joined status. Carries the climb's display facts
     * (snapshotted on the event) so the view renders a thumbnail + grade/angle/time with no catalog re-fetch.
     */
    data class Row(val event: LitEvent, val status: Status) {
        val id: String get() = event.id
    }

    /**
     * A day/session group: a headline (day + the dominant angle or board), a roll-up summary
     * ("9 lit · 3 sent"), and its rows newest-first. [id] is the group key.
     */
    data class Group(
        val id: String,
        val headline: String,
        val summary: String,
        val rows: List<Row>,
    )

    /** A selectable timeline filter (status / angle / board) — the chip's raw vocabulary. */
    enum class Facet(val label: String) {
        STATUS("Status"), ANGLE("Angle"), BOARD("Board"),
    }

    /** The whole grouped, filtered timeline the view renders, plus the hero count and the chip rail. */
    data class DisplayModel(
        val groups: List<Group>,
        /** Distinct climbs (by normalized uuid) worked over the deduped set — the hero "N climbs worked". */
        val climbsWorked: Int,
        /**
         * Distinct selectable values per facet, in render order (the chip rail's content). Built from the
         * FULL deduped set so a chip never vanishes just because the current filter hid its rows.
         */
        val facetValues: Map<Facet, List<String>>,
    )

    // MARK: - Dedup

    /**
     * Collapse the raw lit events to ONE per `(normalized climbUuid, sessionId)` — the same key capture
     * upserts on, applied again here so a backup-restored or hand-duplicated set still reads cleanly. The
     * surviving row is the one with the newest [LitEvent.litAt] (ties broken by [tieBreakPrefers] for
     * determinism). A `null` session is its own bucket per climb (an out-of-session light isn't merged
     * across visits).
     */
    fun deduped(events: List<LitEvent>): List<LitEvent> {
        val best = LinkedHashMap<DedupKey, LitEvent>()
        for (e in events) {
            val key = DedupKey(normalizedUuid(e.climbUuid), e.sessionId)
            val existing = best[key]
            if (existing == null ||
                e.litAt > existing.litAt ||
                (e.litAt == existing.litAt && tieBreakPrefers(e, existing))
            ) {
                best[key] = e
            }
        }
        return best.values.toList()
    }

    private data class DedupKey(val climb: String, val session: String?)

    /**
     * Deterministic tie-break for two rows in the SAME climb+session bucket that share an identical [litAt]:
     * the value-derived [LitEvent.id] collides in that case — same normalized climb, same session, same
     * instant — so falling back to it just preserved input order. Prefer the row that [LitEvent.wasConnected]
     * (a real on-the-wall light beats an intent-only tap), then the higher angle, then the raw climbUuid,
     * then [LitEvent.sizeId] — a total, input-order-independent order so the surviving row (and the
     * [recent]/[group] sort below) is stable across re-queries and round-trips.
     */
    fun tieBreakPrefers(a: LitEvent, b: LitEvent): Boolean {
        if (a.wasConnected != b.wasConnected) return a.wasConnected   // connected wins
        if (a.angle != b.angle) return a.angle > b.angle              // steeper wins
        if (a.climbUuid != b.climbUuid) return a.climbUuid < b.climbUuid
        return a.sizeId < b.sizeId
    }

    // MARK: - Status join

    /**
     * Resolve a lit climb's status from the ascent log: a send/flash anywhere on that climb → [Status.SENT];
     * else any `ATTEMPT` → [Status.ATTEMPT]; else [Status.LIT] (lit-only, or only ever a project). Joined by
     * the **normalized** climb uuid so a created climb's uuid casing/whitespace can't split the join.
     */
    fun status(climbUuid: String, logs: List<LogRow>): Status {
        val key = normalizedUuid(climbUuid)
        val matching = logs.filter { normalizedUuid(it.climbUuid) == key }
        if (matching.any { it.isSend }) return Status.SENT
        if (matching.any { it.status == KilterAscentStatus.ATTEMPT }) return Status.ATTEMPT
        return Status.LIT
    }

    // MARK: - Build

    /**
     * Build the grouped display model from the lit events + the ascent log, a filter selection, and a clock.
     * [layoutName] resolves a `layoutId` to a human board name for the group headline + the Board facet chips
     * (the view passes the catalog lookup; tests pass a stub).
     *
     * @param nowMillis the clock (epoch millis) for relative-day labels.
     * @param zone the time zone for day bucketing + relative-day labels.
     */
    fun build(
        events: List<LitEvent>,
        logs: List<LogRow>,
        selections: Map<Facet, String> = emptyMap(),
        nowMillis: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
        layoutName: (Int) -> String? = { null },
    ): DisplayModel {
        val deduped = deduped(events)
        val allRows = deduped.map { Row(it, status(climbUuid = it.climbUuid, logs = logs)) }

        // Facet values from the FULL deduped set (pre-filter) so toggling a chip can't make others vanish.
        val facetValues = facetValues(allRows, layoutName)

        val filtered = allRows.filter { matches(it, selections, layoutName) }
        val groups = group(filtered, nowMillis, zone, layoutName)

        // Hero count is over the FULL deduped set (the climber's whole body of work), not the filtered view.
        val climbsWorked = deduped.map { normalizedUuid(it.climbUuid) }.toSet().size

        return DisplayModel(groups = groups, climbsWorked = climbsWorked, facetValues = facetValues)
    }

    /** Whether a row passes every active facet (AND-combined). */
    fun matches(row: Row, selections: Map<Facet, String>, layoutName: (Int) -> String?): Boolean {
        for ((facet, value) in selections) {
            when (facet) {
                Facet.STATUS -> if (statusToken(row.status) != value) return false
                Facet.ANGLE -> if (angleToken(row.event.angle) != value) return false
                Facet.BOARD -> if (boardToken(row.event, layoutName) != value) return false
            }
        }
        return true
    }

    /**
     * Distinct selectable values per facet, each in a stable render order. Over the FULL deduped set so the
     * chip rail is constant regardless of the current filter. Empty facets are dropped.
     */
    fun facetValues(rows: List<Row>, layoutName: (Int) -> String?): Map<Facet, List<String>> {
        val out = LinkedHashMap<Facet, List<String>>()

        // Status: canonical Lit → Attempt → Sent order, only those present.
        val presentStatuses = rows.map { it.status }.toSet()
        out[Facet.STATUS] = listOf(Status.LIT, Status.ATTEMPT, Status.SENT)
            .filter { it in presentStatuses }
            .map(::statusToken)

        // Angle: ascending.
        out[Facet.ANGLE] = rows.map { it.event.angle }.toSortedSet().map(::angleToken)

        // Board: distinct layout tokens, by first appearance among newest-first rows.
        val seen = HashSet<String>()
        out[Facet.BOARD] = rows.sortedWith { a, b -> b.event.litAt.compareTo(a.event.litAt) }
            .mapNotNull { r ->
                val token = boardToken(r.event, layoutName)
                if (seen.add(token)) token else null
            }

        return out.filterValues { it.isNotEmpty() }
    }

    // MARK: - Grouping + roll-ups

    /**
     * Bucket the (already deduped + filtered) rows by day **and session** — a day can hold more than one
     * session, and each session gets its own group so the wireframe's "Today · 40°" / "Yesterday ·
     * BetaBoulders Gym" headers read right. Newest group first; rows within a group newest-first.
     *
     * The group key is `epochDay | sessionId` (a `null`-session bucket per day collects out-of-session
     * lights). The headline pairs the relative-day label with the group's dominant board name (when one
     * layout dominates) else its dominant angle. The summary is the "N lit · M sent" roll-up.
     */
    fun group(rows: List<Row>, nowMillis: Long, zone: ZoneId, layoutName: (Int) -> String?): List<Group> {
        if (rows.isEmpty()) return emptyList()

        val keyed = rows.groupBy { r -> GroupKey(epochDay(r.event.litAt, zone), r.event.sessionId) }

        // Sort groups by each group's newest light, newest first; ties broken by the string key.
        return keyed.map { (key, groupRows) ->
            val sortedRows = groupRows.sortedWith { a, b -> if (rowOrdersBefore(a, b)) -1 else 1 }
            val newest = sortedRows.first().event.litAt
            val id = "${key.epochDay}|${key.session ?: "none"}"
            val g = Group(
                id = id,
                headline = headline(sortedRows, key.epochDay, nowMillis, zone, layoutName),
                summary = summary(sortedRows),
                rows = sortedRows,
            )
            Triple(newest, id, g)
        }
            .sortedWith(compareByDescending<Triple<Long, String, Group>> { it.first }.thenBy { it.second })
            .map { it.third }
    }

    private data class GroupKey(val epochDay: Long, val session: String?)

    /**
     * "Today · 40°" / "Yesterday · BetaBoulders Gym" / "Jun 12 · 45°". Pairs the relative-day label with the
     * group's dominant board name when one layout dominates (and resolves to a name), else its dominant angle.
     */
    fun headline(
        rows: List<Row>, epochDay: Long, nowMillis: Long, zone: ZoneId, layoutName: (Int) -> String?,
    ): String {
        val dayLabel = relativeDayLabel(epochDay, nowMillis, zone)
        // Dominant board name (most-frequent layout that resolves to a real name).
        // Most-frequent layout; on a count tie the SMALLER layoutId wins (mirrors the iOS `max(by:)`).
        val boardCounts = rows.groupingBy { it.event.layoutId }.eachCount()
        val topLayout = boardCounts.entries
            .maxWithOrNull(compareBy<Map.Entry<Int, Int>>({ it.value }, { -it.key }))?.key
        if (topLayout != null) {
            val name = layoutName(topLayout)
            if (!name.isNullOrEmpty()) return "$dayLabel · $name"
        }
        // Else dominant angle; same tie rule — on a count tie the SMALLER angle wins.
        val angleCounts = rows.groupingBy { it.event.angle }.eachCount()
        val topAngle = angleCounts.entries
            .maxWithOrNull(compareBy<Map.Entry<Int, Int>>({ it.value }, { -it.key }))?.key
        if (topAngle != null) return "$dayLabel · $topAngle°"
        return dayLabel
    }

    /**
     * "9 lit · 3 sent" — the lit count is the group's total rows; sent is how many resolved to [Status.SENT].
     * (A row's status is the climb's overall status, so "lit" here means "climbs worked", matching the
     * wireframe's "N lit · M sent" header.)
     */
    fun summary(rows: List<Row>): String {
        val sent = rows.count { it.status == Status.SENT }
        return "${rows.size} lit · $sent sent"
    }

    // MARK: - Recent rail

    /**
     * The most-recent lit climbs for the Kilter-root "Recently on the board" rail — deduped (one per
     * climb-per-session), newest light first, capped at [limit]. Ties on [litAt] broken by [tieBreakPrefers]
     * (then [LitEvent.id]) so the rail order is deterministic.
     */
    fun recent(events: List<LitEvent>, logs: List<LogRow> = emptyList(), limit: Int = 8): List<Row> =
        deduped(events)
            .sortedWith { a, b -> if (litEventOrdersBefore(a, b)) -1 else 1 }
            .take(maxOf(0, limit))
            .map { Row(it, status(climbUuid = it.climbUuid, logs = logs)) }

    /**
     * Newest-light-first ordering for two **distinct** deduped rows, with a deterministic tie-break: newer
     * [litAt] first; on an identical instant, the [tieBreakPrefers] row first, then the value [LitEvent.id]
     * as the final stable fallback — a total order regardless of input order.
     */
    fun litEventOrdersBefore(a: LitEvent, b: LitEvent): Boolean {
        if (a.litAt != b.litAt) return a.litAt > b.litAt
        if (tieBreakPrefers(a, b)) return true
        if (tieBreakPrefers(b, a)) return false
        return a.id < b.id
    }

    /** The [Row] form of [litEventOrdersBefore] (groups sort [Row]s). */
    fun rowOrdersBefore(a: Row, b: Row): Boolean = litEventOrdersBefore(a.event, b.event)

    // MARK: - Token + label helpers

    fun statusToken(status: Status): String = status.label

    fun angleToken(angle: Int): String = "$angle°"

    fun boardToken(event: LitEvent, layoutName: (Int) -> String?): String =
        layoutName(event.layoutId) ?: "Layout ${event.layoutId}"

    /**
     * Lowercased, whitespace-trimmed climb uuid — the join/dedup key, so a created climb's casing or stray
     * whitespace can't split the same climb across rows. Delegates to the shared [KilterClimbId] so this
     * feature's key can't drift from the gallery's.
     */
    fun normalizedUuid(uuid: String): String = KilterClimbId.normalize(uuid)

    // MARK: - Day bucketing + relative labels

    /** The local epoch-day (days since 1970-01-01 in [zone]) — the day-bucket key for grouping. */
    private fun epochDay(millis: Long, zone: ZoneId): Long =
        Instant.ofEpochMilli(millis).atZone(zone).toLocalDate().toEpochDay()

    /** "Today" / "Yesterday" / "Jun 12" for [epochDay] relative to [nowMillis], in [zone]. */
    fun relativeDayLabel(epochDay: Long, nowMillis: Long, zone: ZoneId): String {
        val today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate().toEpochDay()
        return when (epochDay) {
            today -> "Today"
            today - 1 -> "Yesterday"
            else -> java.time.LocalDate.ofEpochDay(epochDay)
                .format(DateTimeFormatter.ofPattern("MMM d", Locale.US))
        }
    }
}
