package com.snappet.mobile.feature.kilter

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Pure, device-free logic behind the redesigned Kilter **session history** (Kilter Improvement P4),
 * ported from the iOS `KilterHistoryModel`: bucketing sessions into month/week/all groups with roll-up
 * headers, a scope switcher, faceted filtering (board/layout · angle · grade · status · source) + text
 * search with scope-aware stale-filter recovery, and the adaptive per-card fact selection (the Strava
 * "one badge max" rule).
 *
 * No Room / Compose / Android-UI deps — only `java.util.Calendar` (the module's date convention) over
 * epoch-millis `Long` — so the whole grouped display model is unit-tested in plain JVM tests without an
 * emulator. Views build [SessionItem] / [HistoryLog] value rows from their DB rows and read the result.
 *
 * **Kilter-board data only** (no Quick-Session fold-in). Deterministic for a given input + clock +
 * calendar. The [calendar] lambda lets tests inject a fixed UTC / Monday calendar so month/week
 * bucketing is stable across CI time zones (mirrors the iOS tests passing an explicit `Calendar`).
 */
object KilterHistoryModel {

    /** Builds a fresh mutable [Calendar] for date math; `Calendar` is stateful so we never share one. */
    fun interface CalendarFactory {
        fun make(): Calendar
    }

    /** The default factory: the device's local calendar (matches iOS `Calendar.current`). */
    val systemCalendar: CalendarFactory = CalendarFactory { Calendar.getInstance() }

    // MARK: - Input value types (plain mirrors of the Room entities)

    /** One board session, reduced to what history needs (a value mirror of [KilterSession]). */
    data class SessionItem(
        val id: String,
        /** Epoch millis. */
        val startedAt: Long,
        /** Epoch millis; `null` while the session is still open. */
        val endedAt: Long? = null,
        val angle: Int,
        /** [KilterSession.source] raw (`"ble"` / `"manual"` / `"auto"`). */
        val source: String,
        /** Layout id; `null` for sessions captured before the field existed. */
        val layoutId: Int? = null,
        /** User title; `null` falls back to the date label. */
        val title: String? = null,
        /** Whether the session captured a live HR series (drives the heart glyph). No HR payload here. */
        val hasHR: Boolean = false,
    ) {
        /** Still open (`endedAt == null`) — the live pulse + always-visible recovery row. */
        val isActive: Boolean get() = endedAt == null

        companion object {
            /** Map a Room [KilterSession] to the value-mirror history item (pure model never touches Room). */
            fun from(session: KilterSession): SessionItem = SessionItem(
                id = session.id,
                startedAt = session.startedAt,
                endedAt = session.endedAt,
                angle = session.angle,
                source = session.source,
                // KilterSession on Android has no layoutId/title columns yet; default to null.
                layoutId = null,
                title = null,
                hasHR = (session.hrSampleCount ?: 0) > 0,
            )
        }
    }

    /**
     * One logged climb in pure value form (a value mirror of [KilterLogEntry]). `loggedAt` is epoch
     * millis. `sessionId` is `null` for ad-hoc ascents logged outside a board session. Mirrors the iOS
     * `KilterClimbLog` value type (the Android [KilterLogEntry] column is `createdAt`; adapt to `loggedAt`
     * here). Parallels [KilterSessionStats.SessionLog].
     */
    data class HistoryLog(
        val climbUuid: String,
        val climbName: String,
        val gradeLabel: String,
        val difficulty: Double,
        val status: KilterAscentStatus,
        val attempts: Int = 1,
        /** Epoch millis the climb was logged. */
        val loggedAt: Long,
        /** The board session this was logged in; `null` for an ad-hoc ascent. */
        val sessionId: String? = null,
    ) {
        val isSend: Boolean get() = status.isSend

        companion object {
            /** Map a Room [KilterLogEntry] to the value-mirror log row. */
            fun from(entry: KilterLogEntry): HistoryLog = HistoryLog(
                climbUuid = entry.climbUuid,
                climbName = entry.climbName,
                gradeLabel = entry.gradeLabel,
                difficulty = entry.difficulty,
                status = KilterAscentStatus.from(entry.status),
                attempts = entry.attempts,
                loggedAt = entry.createdAt,
                sessionId = entry.sessionId,
            )
        }
    }

    // MARK: - Scope

    /** The history scope switcher: which trailing window of sessions is shown, and how they're bucketed. */
    enum class Scope(val label: String) {
        WEEK("Week"), MONTH("Month"), ALL("All");
    }

    // MARK: - Facets

    /**
     * Which axis a filter chip narrows. Each maps to one value space; an active selection on a facet keeps
     * only sessions matching it. (`BOARD` doubles as layout — a session's `layoutId`.)
     */
    enum class Facet(val label: String) {
        BOARD("Board"), ANGLE("Angle"), GRADE("Grade"), STATUS("Status"), SOURCE("Source");
    }

    /**
     * The full filter state: at most one selected value per facet (a raw string token), plus the search
     * text. An absent facet entry is "any". Selection tokens are the same raw strings the chips render.
     */
    data class Filters(
        val selections: Map<Facet, String> = emptyMap(),
        val search: String = "",
    ) {
        /** Whether any facet or the search box is narrowing — gates the "Clear filters" affordance. */
        val isActive: Boolean
            get() = selections.isNotEmpty() || search.trim().isNotEmpty()

        /** Toggle a facet value: select it, or clear it if it was already the selection (chip re-tap). */
        fun toggle(facet: Facet, value: String): Filters {
            val next = selections.toMutableMap()
            if (next[facet] == value) next.remove(facet) else next[facet] = value
            return copy(selections = next)
        }
    }

    // MARK: - Adaptive card facts

    /** One fact rendered on an adaptive session card. The view maps [kind] to an icon/tint. */
    data class CardFact(val kind: Kind, val value: String, val label: String) {
        enum class Kind { SENDS, HARDEST, DURATION, FLASH_RATE, PROJECTS, PR_BADGE, LIVE, PROVENANCE }
    }

    /**
     * The fully-resolved per-card model: the default three facts (Sends · Hardest · Duration) with at most
     * ONE notable badge swapped in, plus the provenance glyph and the live flag.
     */
    data class CardModel(
        val id: String,
        val title: String,
        /** The 3 primary facts shown on the card face. */
        val facts: List<CardFact>,
        /** At most one notable badge (flash-rate / PR / # projects) — the Strava rule. `null` when nothing. */
        val badge: CardFact?,
        val provenance: CardFact,
        val isLive: Boolean,
    )

    // MARK: - Display model

    /** One leaf session in a group — the card model plus the originating session (so the view can place it). */
    data class SessionRow(val session: SessionItem, val card: CardModel) {
        val id: String get() = session.id
    }

    /**
     * A roll-up group header + its sessions. [id] is the period label (`"2026-06"` / `"2026-W24"` /
     * `"all"`); [headline] is the human header ("June 2026"); [summary] is the roll-up line
     * ("7 sessions · 41 sent · hardest V7").
     */
    data class Group(
        val id: String,
        val headline: String,
        val summary: String,
        val rows: List<SessionRow>,
    )

    /**
     * What recovery to offer when active filters leave the current scope empty — pointing the user at the
     * control that actually helps (mirrors the iOS FG fix):
     *   • [NONE] — nothing to recover (groups exist, or a genuinely empty history with no filters).
     *   • [WIDEN_SCOPE] — the filters DO match sessions, just not in the current scope's window → suggest
     *     widening the scope (clearing filters wouldn't surface the matches; they're in another period).
     *   • [CLEAR_FILTERS] — the filters match NOTHING anywhere → suggest clearing them.
     */
    enum class StaleFilterRecovery { NONE, WIDEN_SCOPE, CLEAR_FILTERS }

    /** The whole grouped, filtered history the view renders. */
    data class DisplayModel(
        val groups: List<Group>,
        /**
         * Distinct selectable values per facet, in render order (the chip rail's content). Built from the
         * FULL session+log set so a chip never vanishes just because the current filter hid its rows.
         */
        val facetValues: Map<Facet, List<String>>,
        /** The scope-aware recovery affordance to surface — which control will actually help. */
        val staleRecovery: StaleFilterRecovery,
        val totalSessions: Int,
    ) {
        /**
         * Back-compat: true when ANY recovery is offered (the current scope is empty under active filters).
         * Prefer [staleRecovery] to choose the affordance's wording/target.
         */
        val isStaleFilter: Boolean get() = staleRecovery != StaleFilterRecovery.NONE
    }

    // MARK: - Build

    /**
     * Build the grouped display model from the value-mirror sessions + their logs, a scope, the filter
     * state, and a clock. [layoutName] resolves a `layoutId` to a human board name for the Board facet
     * chips + provenance (the view passes the catalog lookup; tests pass a stub).
     */
    fun build(
        sessions: List<SessionItem>,
        logs: List<HistoryLog>,
        scope: Scope,
        filters: Filters,
        now: Long,
        calendar: CalendarFactory = systemCalendar,
        layoutName: (Int) -> String? = { null },
    ): DisplayModel {
        val logsBySession: Map<String, List<HistoryLog>> =
            logs.mapNotNull { l -> l.sessionId?.let { it to l } }
                .groupBy({ it.first }, { it.second })

        // Facet values come from the FULL set (pre-filter) so toggling a chip can't make others vanish.
        val facetValues = facetValues(sessions, logs, layoutName)

        // Scope window first, then facet/search filtering.
        val scoped = inScope(sessions, scope, now, calendar)
        val filtered = scoped.filter {
            matches(it, logsBySession[it.id] ?: emptyList(), filters, layoutName)
        }

        // Prior-hardest per session (the PR-badge baseline): the hardest send across every session that
        // started STRICTLY earlier — computed over the full set so a PR is global, not scoped/filtered.
        val priorHardest = priorHardestBySession(sessions, logsBySession)

        val groups = group(filtered, logsBySession, priorHardest, scope, now, calendar)

        // Scope-aware recovery: only when filters are active AND the current scope is empty. If the SAME
        // filters still match a session somewhere in the full set, the matches are merely in another period
        // → suggest widening scope; if they match nothing at all → suggest clearing filters.
        val recovery: StaleFilterRecovery =
            if (groups.isEmpty() && filters.isActive && sessions.isNotEmpty()) {
                val matchesAnywhere = sessions.any {
                    matches(it, logsBySession[it.id] ?: emptyList(), filters, layoutName)
                }
                if (matchesAnywhere) StaleFilterRecovery.WIDEN_SCOPE else StaleFilterRecovery.CLEAR_FILTERS
            } else {
                StaleFilterRecovery.NONE
            }

        return DisplayModel(
            groups = groups,
            facetValues = facetValues,
            staleRecovery = recovery,
            totalSessions = sessions.size,
        )
    }

    // MARK: - Scope windowing

    /**
     * Keep sessions that fall inside the scope's trailing window from [now]: [Scope.WEEK] = the current
     * calendar week, [Scope.MONTH] = the current calendar month, [Scope.ALL] = everything. Newest-first.
     * An active session is always kept regardless of scope.
     */
    fun inScope(sessions: List<SessionItem>, scope: Scope, now: Long, calendar: CalendarFactory): List<SessionItem> {
        val sorted = sessions.sortedByDescending { it.startedAt }
        return when (scope) {
            Scope.ALL -> sorted
            Scope.WEEK -> {
                val (start, end) = weekInterval(now, calendar)
                sorted.filter { (it.startedAt in start until end) || it.isActive }
            }
            Scope.MONTH -> {
                val (start, end) = monthInterval(now, calendar)
                sorted.filter { (it.startedAt in start until end) || it.isActive }
            }
        }
    }

    // MARK: - Faceted filtering + stale detection

    /**
     * Whether a session passes every active facet + the search query (all AND-combined). [logs] are this
     * session's logs (for the grade/status facets + name search over climbs).
     */
    fun matches(
        session: SessionItem,
        logs: List<HistoryLog>,
        filters: Filters,
        layoutName: (Int) -> String?,
    ): Boolean {
        for ((facet, value) in filters.selections) {
            when (facet) {
                Facet.BOARD -> if (boardToken(session, layoutName) != value) return false
                Facet.ANGLE -> if (angleToken(session.angle) != value) return false
                Facet.GRADE -> if (logs.none { it.gradeLabel == value }) return false
                Facet.STATUS -> if (logs.none { it.status.name == value }) return false
                Facet.SOURCE -> if (sourceToken(session.source) != value) return false
            }
        }
        val q = filters.search.trim().lowercase(Locale.getDefault())
        if (q.isEmpty()) return true
        // Search matches the title, the board name, or any climb name in the session.
        session.title?.lowercase(Locale.getDefault())?.let { if (it.contains(q)) return true }
        session.layoutId?.let(layoutName)?.lowercase(Locale.getDefault())?.let { if (it.contains(q)) return true }
        return logs.any { it.climbName.lowercase(Locale.getDefault()).contains(q) }
    }

    /**
     * Distinct selectable values per facet, each in a stable render order. Built over the FULL data set
     * (every session + every log) so the chip rail is constant regardless of the current filter. Empty
     * facets are dropped so the view only renders chips that can do something.
     */
    fun facetValues(
        sessions: List<SessionItem>,
        logs: List<HistoryLog>,
        layoutName: (Int) -> String?,
    ): Map<Facet, List<String>> {
        val out = LinkedHashMap<Facet, List<String>>()

        // Board: distinct layout tokens, by first appearance among newest-first sessions.
        val seenBoard = LinkedHashSet<String>()
        out[Facet.BOARD] = sessions.sortedByDescending { it.startedAt }
            .mapNotNull { s ->
                val token = boardToken(s, layoutName)
                if (seenBoard.add(token)) token else null
            }

        // Angle: ascending.
        out[Facet.ANGLE] = sessions.map { it.angle }.distinct().sorted().map(::angleToken)

        // Source: in a fixed canonical order, only those present.
        val presentSources = sessions.map { sourceToken(it.source) }.toSet()
        out[Facet.SOURCE] = listOf("BLE", "Manual").filter { it in presentSources }

        // Grade: distinct grade labels, hardest→easiest by their representative difficulty, tie-broken by
        // the gradeLabel string so two labels at the same difficulty order deterministically.
        val hardestByLabel = HashMap<String, Double>()
        for (l in logs) {
            hardestByLabel[l.gradeLabel] = maxOf(hardestByLabel[l.gradeLabel] ?: Double.NEGATIVE_INFINITY, l.difficulty)
        }
        out[Facet.GRADE] = hardestByLabel.keys.sortedWith(
            compareByDescending<String> { hardestByLabel[it] ?: 0.0 }.thenBy { it }
        )

        // Status: canonical order, only those present.
        val presentStatuses = logs.map { it.status }.toSet()
        out[Facet.STATUS] = KilterAscentStatus.entries.filter { it in presentStatuses }.map { it.name }

        // Drop empty facets so the view only renders chips that can do something.
        return out.filterValues { it.isNotEmpty() }
    }

    // MARK: - Grouping + roll-ups

    /**
     * Bucket the (already scoped + filtered) sessions into period groups, newest period first, with a
     * roll-up summary header per group. [Scope.WEEK]/[Scope.MONTH] bucket by ISO week / calendar month;
     * [Scope.ALL] is a single "All sessions" group (the timeline scrolls one list).
     *
     * An ACTIVE session (`endedAt == null`) is bucketed by the CURRENT period ([now]), not its own
     * possibly-old `startedAt` — so a session that's been open since last week never renders a stale
     * week/month header in Week/Month scope. Its grouping date is pinned to [now] for both the bucket key
     * and the header.
     */
    fun group(
        sessions: List<SessionItem>,
        logsBySession: Map<String, List<HistoryLog>>,
        priorHardest: Map<String, Double> = emptyMap(),
        scope: Scope,
        now: Long = System.currentTimeMillis(),
        calendar: CalendarFactory = systemCalendar,
    ): List<Group> {
        if (sessions.isEmpty()) return emptyList()

        // The date a session is bucketed/headlined by: `now` for an active session (so it lands in the
        // current period, never a stale one), else its real `startedAt`.
        fun groupingDate(s: SessionItem): Long = if (s.isActive) now else s.startedAt

        fun rows(ss: List<SessionItem>): List<SessionRow> =
            ss.sortedByDescending { it.startedAt }.map { s ->
                SessionRow(s, card(s, logsBySession[s.id] ?: emptyList(), priorHardest[s.id]))
            }

        if (scope == Scope.ALL) {
            val summary = rollupSummary(sessions, logsBySession)
            return listOf(Group("all", "All sessions", summary, rows(sessions)))
        }

        val keyed: Map<String, List<SessionItem>> = sessions.groupBy { s ->
            if (scope == Scope.WEEK) weekKey(groupingDate(s), calendar) else monthKey(groupingDate(s), calendar)
        }
        return keyed.keys.sortedDescending().map { key ->
            val ss = keyed.getValue(key)
            // Headline off a grouping date in THIS bucket (so an active session pinned to `now` headlines
            // the current period, not its stale start). All members share the key, so any one works.
            val headlineDate = groupingDate(ss[0])
            Group(
                id = key,
                headline = if (scope == Scope.WEEK) weekHeadline(headlineDate, calendar)
                           else monthHeadline(headlineDate, calendar),
                summary = rollupSummary(ss, logsBySession),
                rows = rows(ss),
            )
        }
    }

    /**
     * For each session, the hardest send difficulty across every session that started STRICTLY earlier
     * (the PR baseline). A session with no earlier *send* is absent from the map → the card treats it as
     * "first-ever" and badges a PR whenever it sent something.
     */
    fun priorHardestBySession(
        sessions: List<SessionItem>,
        logsBySession: Map<String, List<HistoryLog>>,
    ): Map<String, Double> {
        // Tie-break identical `startedAt` by id so the running-max walk (and thus which session is awarded
        // the PR) is deterministic for sessions started at the same instant.
        val chronological = sessions.sortedWith(compareBy<SessionItem> { it.startedAt }.thenBy { it.id })
        val out = HashMap<String, Double>()
        var running: Double? = null // hardest send seen so far (across earlier sessions)
        for (s in chronological) {
            running?.let { out[s.id] = it } // absent when no earlier send yet
            val hardestHere = (logsBySession[s.id] ?: emptyList())
                .filter { it.isSend }.maxOfOrNull { it.difficulty }
            if (hardestHere != null) running = maxOf(running ?: Double.NEGATIVE_INFINITY, hardestHere)
        }
        return out
    }

    /**
     * The roll-up header line: "7 sessions · 41 sent · hardest V7" (the hardest clause drops when nothing
     * was sent in the period).
     */
    fun rollupSummary(
        sessions: List<SessionItem>,
        logsBySession: Map<String, List<HistoryLog>>,
    ): String {
        val logs = sessions.flatMap { logsBySession[it.id] ?: emptyList() }
        val sends = logs.filter { it.isSend }
        val sent = sends.size
        // Hardest send, tie-broken by gradeLabel so two equally-hard sends pick the same label every time.
        val hardest = sends.maxWithOrNull(
            compareBy<HistoryLog> { it.difficulty }.thenByDescending { it.gradeLabel }
        )?.gradeLabel
        val parts = mutableListOf(
            "${sessions.size} session${if (sessions.size == 1) "" else "s"}",
            "$sent sent",
        )
        if (hardest != null) parts.add("hardest $hardest")
        return parts.joinToString(" · ")
    }

    // MARK: - Adaptive card facts

    /**
     * Build the adaptive card model for one session (Strava rule — exactly ONE notable badge at most).
     * Default facts: Sends · Hardest · Duration. The badge swaps in the most notable of: a flash-rate chip
     * (≥1 flash and flash-rate ≥ 0.5), a PR badge (this session set a new hardest send vs the rest — passed
     * in as [priorHardestDifficulty]), or # projects (≥1 project). PR wins over flash wins over projects.
     */
    fun card(
        session: SessionItem,
        logs: List<HistoryLog>,
        priorHardestDifficulty: Double? = null,
    ): CardModel {
        val sends = logs.filter { it.isSend }
        val hardest = sends.maxByOrNull { it.difficulty }
        val projects = logs.count { it.status == KilterAscentStatus.PROJECT }
        val flashes = logs.count { it.status == KilterAscentStatus.FLASH }

        val facts = listOf(
            CardFact(CardFact.Kind.SENDS, "${sends.size}", if (sends.size == 1) "send" else "sends"),
            CardFact(CardFact.Kind.HARDEST, hardest?.gradeLabel ?: "—", "hardest"),
            CardFact(CardFact.Kind.DURATION, durationLabel(session), "duration"),
        )

        val badge = notableBadge(sends.size, flashes, projects, hardest, priorHardestDifficulty)

        val prov = CardFact(
            kind = CardFact.Kind.PROVENANCE,
            value = sourceToken(session.source),
            label = if (session.source == "ble") "Auto-captured" else "Logged by hand",
        )

        return CardModel(
            id = session.id,
            title = session.title ?: defaultTitle(session),
            facts = facts,
            badge = badge,
            provenance = prov,
            isLive = session.isActive,
        )
    }

    /**
     * The ONE notable badge (or none). Priority: PR > flash-rate > projects — so the rarest, most
     * celebration-worthy signal wins the single slot.
     */
    fun notableBadge(
        sends: Int,
        flashes: Int,
        projects: Int,
        hardest: HistoryLog?,
        priorHardestDifficulty: Double?,
    ): CardFact? {
        // PR: this session's hardest send beats every prior session's hardest.
        if (hardest != null && priorHardestDifficulty != null && hardest.difficulty > priorHardestDifficulty) {
            return CardFact(CardFact.Kind.PR_BADGE, hardest.gradeLabel, "PR")
        }
        // First-ever hardest (no prior sends anywhere) is also a PR when something was sent.
        if (hardest != null && priorHardestDifficulty == null && sends > 0) {
            return CardFact(CardFact.Kind.PR_BADGE, hardest.gradeLabel, "PR")
        }
        // Flash-rate: notable when ≥1 flash AND at least half the sends were flashes.
        if (flashes > 0 && sends > 0 && flashes.toDouble() / sends.toDouble() >= 0.5) {
            val pct = Math.round(flashes.toDouble() / sends.toDouble() * 100).toInt()
            return CardFact(CardFact.Kind.FLASH_RATE, "$pct%", "flash rate")
        }
        // Projects: notable when the session worked ≥1 project.
        if (projects > 0) {
            return CardFact(CardFact.Kind.PROJECTS, "$projects", if (projects == 1) "project" else "projects")
        }
        return null
    }

    // MARK: - Token + label helpers (the chips' raw vocabulary)

    fun boardToken(session: SessionItem, layoutName: (Int) -> String?): String =
        session.layoutId?.let(layoutName) ?: session.layoutId?.let { "Layout $it" } ?: "Board"

    fun angleToken(angle: Int): String = "$angle°"

    fun sourceToken(source: String): String = if (source == "ble") "BLE" else "Manual"

    /** e.g. "Monday, Jun 10" — mirrors the iOS weekday-day-month date label. */
    fun defaultTitle(session: SessionItem): String = dateLabel(session.startedAt)

    fun durationLabel(session: SessionItem): String {
        val end = session.endedAt ?: return "live"
        val minutes = maxOf(0L, (end - session.startedAt) / 60_000L)
        if (minutes < 60) return "${minutes}m"
        return "${minutes / 60}h ${minutes % 60}m"
    }

    // MARK: - Calendar keys + headlines (java.util.Calendar over epoch-millis)

    fun monthKey(date: Long, calendar: CalendarFactory): String {
        val c = calendar.make().apply { timeInMillis = date }
        return "%04d-%02d".format(c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1)
    }

    fun weekKey(date: Long, calendar: CalendarFactory): String {
        val c = calendar.make().apply { timeInMillis = date }
        // WEEK_YEAR is the year the ISO-ish week belongs to (the iOS `yearForWeekOfYear` twin).
        val weekYear = c.weekYear
        return "%04d-W%02d".format(weekYear, c.get(Calendar.WEEK_OF_YEAR))
    }

    fun monthHeadline(date: Long, calendar: CalendarFactory): String {
        val fmt = SimpleDateFormat("MMMM yyyy", Locale.getDefault())
        fmt.timeZone = calendar.make().timeZone
        return fmt.format(Date(date))
    }

    fun weekHeadline(date: Long, calendar: CalendarFactory): String {
        val (start, end) = weekInterval(date, calendar)
        val tz = calendar.make().timeZone
        val fmt = SimpleDateFormat("MMM d", Locale.getDefault()).apply { timeZone = tz }
        val lastDay = end - DAY_MS // end is exclusive (start of the next week)
        return "Week of ${fmt.format(Date(start))} – ${fmt.format(Date(lastDay))}"
    }

    private fun dateLabel(date: Long): String =
        SimpleDateFormat("EEEE, MMM d", Locale.getDefault()).format(Date(date))

    // MARK: - Interval helpers (half-open [start, end))

    private const val DAY_MS = 86_400_000L

    /** Local start-of-day for an epoch-millis instant under [calendar]'s time zone. */
    internal fun startOfDay(date: Long, calendar: CalendarFactory): Long {
        val c = calendar.make().apply {
            timeInMillis = date
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return c.timeInMillis
    }

    /** The half-open `[start, end)` millis range of the calendar month containing [date]. */
    internal fun monthInterval(date: Long, calendar: CalendarFactory): Pair<Long, Long> {
        val c = calendar.make().apply {
            timeInMillis = date
            set(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val start = c.timeInMillis
        c.add(Calendar.MONTH, 1)
        return start to c.timeInMillis
    }

    /** The half-open `[start, end)` millis range of the calendar week containing [date]. */
    internal fun weekInterval(date: Long, calendar: CalendarFactory): Pair<Long, Long> {
        val c = calendar.make().apply {
            timeInMillis = date
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        // Roll BACK to the calendar's first day of the week (respects the injected firstDayOfWeek).
        // `set(DAY_OF_WEEK, …)` can roll forward; subtracting the offset always lands on this week's start.
        val offset = (c.get(Calendar.DAY_OF_WEEK) - c.firstDayOfWeek + 7) % 7
        c.add(Calendar.DAY_OF_MONTH, -offset)
        val start = c.timeInMillis
        c.add(Calendar.WEEK_OF_YEAR, 1)
        return start to c.timeInMillis
    }
}

/**
 * Pure inputs for the two consistency surfaces (Kilter Improvement P4), ported from the iOS
 * `KilterConsistency`: a GitHub-style activity heatmap and a tappable month calendar. Both are derived
 * from per-day session/send counts so the views are dumb renderers and the bucketing is unit-tested.
 * `java.util.Calendar` over epoch-millis only.
 */
object KilterConsistency {

    private const val DAY_MS = 86_400_000L

    /**
     * One day in either surface: its [date] (local start-of-day epoch millis), how many sessions started
     * that day, how many sends, and an [intensity] 0…1 (window-normalized by the busiest day) the heatmap
     * cell uses for its fill. [sessionIds] lets a tapped cell/day open that day's session(s).
     */
    data class Day(
        val date: Long,
        val sessions: Int,
        val sends: Int,
        val intensity: Double,
        val sessionIds: List<String>,
    ) {
        val id: Long get() = date

        /**
         * A day reads as "active" (gets fill / a dot) when it had a session OR any send — so an ad-hoc
         * send-only day (`sessionId == null`, no session row) still shows activity. Tapping such a day is a
         * no-op (no [sessionIds] to open), but it's no longer invisibly faint.
         */
        val isEmpty: Boolean get() = sessions == 0 && sends == 0
    }

    /**
     * Build a trailing-[weeks]-week heatmap ending at [now], aligned to whole weeks (columns are weeks,
     * rows are weekdays — the GitHub layout). Intensity = a day's sends scaled by the busiest day IN THE
     * WINDOW (so an out-of-window busy day can't crush the visible cells, and the accent always reaches
     * full on the best in-window day). Days with no session are emitted at intensity 0 (the faint cell).
     */
    fun heatmap(
        sessions: List<KilterHistoryModel.SessionItem>,
        logs: List<KilterHistoryModel.HistoryLog>,
        now: Long,
        weeks: Int = 26,
        calendar: KilterHistoryModel.CalendarFactory = KilterHistoryModel.systemCalendar,
    ): List<Day> {
        val (thisWeekStart, _) = KilterHistoryModel.weekInterval(now, calendar)
        val firstWeekStart = thisWeekStart - (maxOf(1, weeks) - 1).toLong() * 7L * DAY_MS

        val countsByDay = countsByDay(sessions, logs, calendar)

        // One cell per day from the first week's start through the end of the current week.
        val lastDay = KilterHistoryModel.startOfDay(thisWeekStart + 6L * DAY_MS, calendar)
        // Collect the window's day keys first so intensity is normalized over the days IN the window.
        val keys = ArrayList<Long>()
        var cursor = KilterHistoryModel.startOfDay(firstWeekStart, calendar)
        while (cursor <= lastDay) {
            keys.add(cursor)
            cursor = KilterHistoryModel.startOfDay(cursor + DAY_MS + DAY_MS / 2, calendar) // +1 day, DST-safe
        }
        val maxSends = keys.mapNotNull { countsByDay[it]?.sends }.maxOrNull() ?: 0
        return keys.map { key ->
            val entry = countsByDay[key]
            val intensity = if (maxSends > 0 && entry != null) entry.sends.toDouble() / maxSends else 0.0
            Day(
                date = key,
                sessions = entry?.sessions ?: 0,
                sends = entry?.sends ?: 0,
                intensity = minOf(1.0, intensity),
                sessionIds = entry?.ids ?: emptyList(),
            )
        }
    }

    /**
     * Build the day cells for the calendar month containing [month] (only the real days of that month, in
     * order) for the tappable month calendar. Empty days carry zero counts so the view can dot only the
     * active ones. Intensity is normalized over THIS month (the calendar twin of the heatmap window-norm).
     */
    fun monthDays(
        sessions: List<KilterHistoryModel.SessionItem>,
        logs: List<KilterHistoryModel.HistoryLog>,
        month: Long,
        calendar: KilterHistoryModel.CalendarFactory = KilterHistoryModel.systemCalendar,
    ): List<Day> {
        val (start, end) = KilterHistoryModel.monthInterval(month, calendar)
        val countsByDay = countsByDay(sessions, logs, calendar)

        // The month's day keys, so intensity is normalized over THIS month (not an out-of-month busy day).
        val keys = ArrayList<Long>()
        var cursor = KilterHistoryModel.startOfDay(start, calendar)
        while (cursor < end) {
            keys.add(cursor)
            cursor = KilterHistoryModel.startOfDay(cursor + DAY_MS + DAY_MS / 2, calendar) // +1 day, DST-safe
        }
        val maxSends = keys.mapNotNull { countsByDay[it]?.sends }.maxOrNull() ?: 0

        return keys.map { key ->
            val entry = countsByDay[key]
            val intensity = if (maxSends > 0 && entry != null) entry.sends.toDouble() / maxSends else 0.0
            Day(
                date = key,
                sessions = entry?.sessions ?: 0,
                sends = entry?.sends ?: 0,
                intensity = minOf(1.0, intensity),
                sessionIds = entry?.ids ?: emptyList(),
            )
        }
    }

    private data class DayTally(var sessions: Int, var sends: Int, val ids: MutableList<String>)

    /**
     * Per-start-of-day tallies for the consistency surfaces. Two facts are bucketed by DIFFERENT days, on
     * purpose:
     *   • **sessions** + **ids** — by the session's `startedAt` local day (a tapped day opens a session
     *     that day).
     *   • **sends** — by each LOG's `loggedAt` local day (NOT its session's `startedAt`), so a send logged
     *     just after midnight lands on the calendar cell it actually happened on; and EVERY send is
     *     counted, including ad-hoc logs with `sessionId == null`, so the surfaces don't under-report.
     */
    private fun countsByDay(
        sessions: List<KilterHistoryModel.SessionItem>,
        logs: List<KilterHistoryModel.HistoryLog>,
        calendar: KilterHistoryModel.CalendarFactory,
    ): Map<Long, DayTally> {
        val out = HashMap<Long, DayTally>()
        for (s in sessions) {
            val key = KilterHistoryModel.startOfDay(s.startedAt, calendar)
            val entry = out.getOrPut(key) { DayTally(0, 0, mutableListOf()) }
            entry.sessions += 1
            entry.ids.add(s.id)
        }
        for (l in logs) {
            if (!l.isSend) continue
            val key = KilterHistoryModel.startOfDay(l.loggedAt, calendar)
            val entry = out.getOrPut(key) { DayTally(0, 0, mutableListOf()) }
            entry.sends += 1
        }
        return out
    }
}
