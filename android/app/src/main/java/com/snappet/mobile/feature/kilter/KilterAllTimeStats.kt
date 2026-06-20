package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.KilterSessionStats.GradeCount
import com.snappet.mobile.feature.kilter.KilterSessionStats.SessionLog
import java.util.Calendar
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Pure, device-free **all-time** statistics over a climber's full Kilter-board log — the aggregate
 * analogue of the per-session [KilterSessionStats]. It lifts the all-time math out of the History UI
 * into one tested value type so the dashboard and history roll-ups / adaptive cards consume tested
 * aggregates instead of re-deriving math in the view. Faithful port of iOS `KilterAllTimeStats`
 * (Phase P0).
 *
 * Foundation-only: NO Room / Compose / Android-UI deps. Operates on plain [SessionLog] rows (built
 * via the renderer from [KilterLogEntry], carrying `angle`/`sessionId`) and an optional list of
 * [SessionSummary] (built via [SessionSummary.from] from [KilterSession]). **Kilter-board data only**
 * (no Quick-Session fold-in). Deterministic for a given input — runs in plain JVM unit tests.
 *
 * Time is epoch **millis** (`Long`), matching the module's [SessionLog]/[KilterSession] convention.
 * Month/week bucketing uses a [Calendar] factory (defaulting to a UTC ISO-8601 calendar: Monday-first,
 * 4-day-minimal weeks) so callers can pin a zone/locale and tests are deterministic.
 */
object KilterAllTimeStats {

    /**
     * A plain-value view of one Kilter board **session**, so the aggregator can count distinct
     * sessions (and read their angles) without touching the Room [KilterSession]. Build with
     * [from]; tests synthesize directly. Mirrors iOS `KilterSessionSummary`.
     */
    data class SessionSummary(
        val id: String,
        val startedAt: Long,
        val endedAt: Long? = null,
        val angle: Int = 0,
    ) {
        companion object {
            /** Map a Room [KilterSession] to the plain-value summary used by the aggregator. */
            fun from(session: KilterSession): SessionSummary =
                SessionSummary(session.id, session.startedAt, session.endedAt, session.angle)
        }
    }

    /** A point on the max-grade progression / a labeled difficulty for a period. */
    data class GradePoint(
        /** Period label (e.g. `"2026-06"`), the stable id. */
        val periodLabel: String,
        val difficulty: Double,
        val gradeLabel: String,
    )

    /** A volume bucket — a count of sends in a labeled time window. */
    data class VolumeBucket(
        /** Window label (e.g. ISO `"2026-W24"`), the stable id. */
        val periodLabel: String,
        /** The window's start (epoch millis), so a chart can place it on a real axis. */
        val start: Long,
        val sends: Int,
    )

    /** Sends & attempts at one board angle. */
    data class AngleCount(val angle: Int, val sends: Int, val attempts: Int)

    /** A per-period roll-up for the history list / adaptive cards. */
    data class PeriodRollup(
        /** Period label (`"2026-06"` for months, `"2026-W24"` for weeks), the stable id. */
        val periodLabel: String,
        val sessions: Int,
        val sends: Int,
        /** Hardest **send** grade label in the period — null when nothing was sent that period. */
        val hardestGradeLabel: String?,
    )

    /** The computed all-time summary. Mirrors iOS `KilterAllTimeStats` (the value type). */
    data class Stats(
        // Volume & counts
        /** Sends across the whole log (sent + flash). */
        val totalSends: Int,
        /** Sum of every climb's `attempts` (each climb counts at least one try) — total "effort". */
        val totalAttempts: Int,
        /** Every logged row (sends + projects + attempts). */
        val totalClimbsLogged: Int,
        /** Distinct climbs (by `climbUuid`) ever logged. */
        val distinctClimbs: Int,
        // Quality ratios (0…1)
        /** `totalSends / totalClimbsLogged` — share of logged climbs that were sent. 0 on empty. */
        val sendRate: Double,
        /** `flashes / totalSends` — share of sends that were first-try flashes. 0 with no sends. */
        val flashRate: Double,
        /** Average `attempts` among **sent** climbs (attempts-to-send velocity). null with no sends. */
        val attemptsToSend: Double?,
        // Grade ceiling & trend
        /** Hardest **send** by float difficulty, ever. null when nothing was sent. */
        val maxGradeDifficulty: Double?,
        val maxGradeLabel: String?,
        /**
         * The windowed "Climbing Level" seed — the working grade ([KilterRecommender.workingDifficulty]
         * logic) over the recent window, with a representative label. null until there are sends.
         *
         * NOTE: a **rounded working-grade bucket**, NOT the raw [maxGradeDifficulty] all-time ceiling.
         * Different metrics on a different numeric axis — callers must not interchange them.
         */
        val climbingLevelDifficulty: Double?,
        val climbingLevelLabel: String?,
        /** Best send difficulty + label per calendar month, chronological — progression series. */
        val maxGradeProgression: List<GradePoint>,
        // Time-series
        /** Sends per week for the trailing window (oldest→newest, zero-filled). */
        val sendsPerWeek: List<VolumeBucket>,
        /** Sends & attempts per board angle, sorted by angle ascending. */
        val angleDistribution: List<AngleCount>,
        // Segmented pyramid (reuses the per-session GradeCount)
        /** All-time grade pyramid, easiest→hardest, flash/send/project/attempt segmented per grade. */
        val pyramid: List<GradeCount>,
        // Period roll-ups
        /** Per calendar-month roll-ups (chronological): sessions, sends, hardest grade label. */
        val monthRollups: List<PeriodRollup>,
        /** Per ISO-week roll-ups (chronological): sessions, sends, hardest grade label. */
        val weekRollups: List<PeriodRollup>,
    ) {
        companion object {
            /** An all-zero / empty value — the cold-start state (no logs yet). */
            val EMPTY = Stats(
                totalSends = 0, totalAttempts = 0, totalClimbsLogged = 0, distinctClimbs = 0,
                sendRate = 0.0, flashRate = 0.0, attemptsToSend = null,
                maxGradeDifficulty = null, maxGradeLabel = null,
                climbingLevelDifficulty = null, climbingLevelLabel = null, maxGradeProgression = emptyList(),
                sendsPerWeek = emptyList(), angleDistribution = emptyList(), pyramid = emptyList(),
                monthRollups = emptyList(), weekRollups = emptyList(),
            )
        }
    }

    /**
     * A [Calendar] factory the bucketing uses. Defaults to a **UTC ISO-8601** calendar (Monday-first,
     * 4-day-minimal weeks) so weeks/months are stable and self-consistent in tests; callers can pass a
     * factory pinned to the user's zone/locale. A fresh instance per call keeps the aggregator pure.
     */
    fun interface CalendarFactory {
        fun new(): Calendar
    }

    /** The default: a fresh UTC, Monday-first, ISO-week [Calendar]. */
    val isoUtcCalendar = CalendarFactory {
        Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            firstDayOfWeek = Calendar.MONDAY
            minimalDaysInFirstWeek = 4 // ISO-8601 week-numbering
        }
    }

    /**
     * Aggregate the full climbing log into all-time stats.
     *
     * @param logs every logged climb (built from [KilterLogEntry] via the renderer).
     * @param sessions persisted board sessions; when supplied, roll-up "sessions" counts come from
     *   here (one session per period it started in). When empty, sessions are counted from the
     *   distinct `sessionId` among that period's logs (ad-hoc logs with no `sessionId` don't count).
     * @param nowMillis the clock (the weekly-volume window ends here).
     * @param calendar the [CalendarFactory] for month/week bucketing (defaults to UTC ISO-8601).
     * @param climbingLevelWindow how many of the most recent sends seed the Climbing Level.
     * @param weeklyVolumeWindow how many trailing weeks of send volume to emit.
     * @param sendThreshold sends-in-a-bucket needed to qualify it as the working grade (recommender).
     */
    fun make(
        logs: List<SessionLog>,
        sessions: List<SessionSummary> = emptyList(),
        nowMillis: Long,
        calendar: CalendarFactory = isoUtcCalendar,
        climbingLevelWindow: Int = 20,
        weeklyVolumeWindow: Int = 8,
        sendThreshold: Int = 2,
    ): Stats {
        if (logs.isEmpty()) return Stats.EMPTY

        val sorted = logs.sortedBy { it.loggedAt }
        // Sends in recency order with a STABLE tie-break (climbUuid, then difficulty) so the
        // recency window (`takeLast(N)`) is deterministic even when many sends share an identical
        // `loggedAt` — common for backfilled / midnight-stamped sessions.
        val sendLogs = sorted.filter { it.isSend }.sortedWith(
            compareBy({ it.loggedAt }, { it.climbUuid }, { it.difficulty }),
        )

        val totalSends = sendLogs.size
        val totalAttempts = sorted.sumOf { maxOf(1, it.attempts) }
        val totalClimbsLogged = sorted.size
        val distinctClimbs = sorted.map { it.climbUuid }.toSet().size
        val flashes = sorted.count { it.status == KilterAscentStatus.FLASH }

        val sendRate = if (totalClimbsLogged > 0) totalSends.toDouble() / totalClimbsLogged else 0.0
        val flashRate = if (totalSends > 0) flashes.toDouble() / totalSends else 0.0
        val attemptsToSend: Double? =
            if (sendLogs.isEmpty()) null
            else sendLogs.sumOf { maxOf(1, it.attempts) }.toDouble() / sendLogs.size

        // Grade ceiling: hardest send ever.
        val hardest = sendLogs.maxByOrNull { it.difficulty }

        // Climbing Level: the working grade over the most recent N sends (recency window), so an old
        // PR doesn't peg the level forever. Reuses the recommender's bucketed working-grade logic.
        val recentSends = sendLogs.takeLast(maxOf(1, climbingLevelWindow))
        val climbingLevelDiff = workingDifficulty(recentSends, sendThreshold)
        val climbingLevelLabel = climbingLevelDiff?.let { lvl -> levelLabel(recentSends, lvl) }

        // Max-grade progression: best send per calendar month, chronological.
        val progression = monthlyBestSends(sendLogs, calendar)

        // Weekly send volume over the trailing window (oldest→newest, zero-filled).
        val weekly = weeklyVolume(sendLogs, nowMillis, calendar, maxOf(1, weeklyVolumeWindow))

        // Angle distribution: sends & attempts per angle.
        val angles = angleDistribution(sorted)

        // All-time segmented pyramid — reuse the per-session segmentation.
        val pyramid = KilterSessionStats.segmentedPyramid(
            sorted, { it.gradeLabel }, { it.difficulty }, { it.status },
        )

        // Period roll-ups.
        val monthRollups = rollups(sorted, sessions, calendar) { millis, cal -> monthKey(millis, cal) }
        val weekRollups = rollups(sorted, sessions, calendar) { millis, cal -> weekKey(millis, cal) }

        return Stats(
            totalSends = totalSends, totalAttempts = totalAttempts,
            totalClimbsLogged = totalClimbsLogged, distinctClimbs = distinctClimbs,
            sendRate = sendRate, flashRate = flashRate, attemptsToSend = attemptsToSend,
            maxGradeDifficulty = hardest?.difficulty, maxGradeLabel = hardest?.gradeLabel,
            climbingLevelDifficulty = climbingLevelDiff, climbingLevelLabel = climbingLevelLabel,
            maxGradeProgression = progression, sendsPerWeek = weekly, angleDistribution = angles,
            pyramid = pyramid, monthRollups = monthRollups, weekRollups = weekRollups,
        )
    }

    // --- Working-grade level (mirrors KilterRecommender.workingDifficulty over SessionLog) -------

    /**
     * The hardest difficulty bucket sent at least [sendThreshold] times (else the hardest single
     * send, else null). Buckets are rounded difficulty — identical to [KilterRecommender] (which
     * works on [KilterLogEntry]; this overload runs the same math on send [SessionLog]s so the
     * aggregator stays Room-free). [sends] must already be filtered to sends.
     */
    private fun workingDifficulty(sends: List<SessionLog>, sendThreshold: Int): Double? {
        if (sends.isEmpty()) return null
        val countByBucket = HashMap<Int, Int>()
        for (s in sends) {
            val b = bucket(s.difficulty)
            countByBucket[b] = (countByBucket[b] ?: 0) + 1
        }
        val qualifying = countByBucket.filterValues { it >= sendThreshold }.keys.maxOrNull()
        if (qualifying != null) return qualifying.toDouble()
        return sends.map { bucket(it.difficulty) }.max().toDouble()
    }

    /**
     * Pick a representative label for the working level deterministically. [workingDifficulty]
     * returns a ROUNDED bucket, so prefer a send whose `difficulty.roundToInt()` lands in that bucket;
     * on ties prefer the higher difficulty, then the lexically smaller `gradeLabel`. Fall back to the
     * send nearest the level by absolute distance (same tie-break) when none round into the bucket.
     */
    private fun levelLabel(recentSends: List<SessionLog>, lvl: Double): String? {
        // Higher difficulty wins; on equal difficulty the lexically smaller label wins.
        val better = Comparator<SessionLog> { a, b ->
            if (a.difficulty != b.difficulty) b.difficulty.compareTo(a.difficulty)
            else a.gradeLabel.compareTo(b.gradeLabel)
        }
        val inBucket = recentSends.filter { it.difficulty.roundToInt() == lvl.roundToInt() }
        if (inBucket.isNotEmpty()) return inBucket.minWith(better).gradeLabel
        // Nearest by absolute distance to the level; ties broken by `better`.
        val nearest = recentSends.minWithOrNull(
            compareBy<SessionLog> { abs(it.difficulty - lvl) }.then(better),
        )
        return nearest?.gradeLabel
    }

    private fun bucket(difficulty: Double): Int = difficulty.roundToInt()

    // --- Private aggregation helpers (all pure) --------------------------------------------------

    /** Best send difficulty + label per calendar month, chronological by month. */
    private fun monthlyBestSends(sendLogs: List<SessionLog>, calendar: CalendarFactory): List<GradePoint> {
        val cal = calendar.new()
        val best = HashMap<String, Pair<Double, String>>() // key -> (difficulty, label)
        for (log in sendLogs) {
            val key = monthKey(log.loggedAt, cal)
            val existing = best[key]
            if (existing != null && existing.first >= log.difficulty) continue
            best[key] = log.difficulty to log.gradeLabel
        }
        return best.entries
            .map { GradePoint(it.key, it.value.first, it.value.second) }
            .sortedBy { it.periodLabel }
    }

    /**
     * Sends per week for the trailing [weeks] weeks ending at [nowMillis] (oldest→newest, zero-filled
     * so a flat-out week still shows a bar at zero).
     *
     * Keyed by the **normalized week-start instant** (not a year+week string). Under a zone-/locale-
     * sensitive calendar those disagree at the new-year boundary — a log in the boundary week can be
     * dropped if matched on the string. Matching purely on the week-start instant (each bucket's
     * start vs. the start of the week containing the log) makes the assignment self-consistent for any
     * calendar. Always emits exactly [weeks] buckets, oldest→newest; logs in weeks after the current
     * one are ignored.
     */
    private fun weeklyVolume(
        sendLogs: List<SessionLog>,
        nowMillis: Long,
        calendar: CalendarFactory,
        weeks: Int,
    ): List<VolumeBucket> {
        val cal = calendar.new()
        val thisWeekStart = weekStart(nowMillis, cal)
        // Bucket starts: this week back to `weeks - 1` weeks ago, oldest→newest. Exactly `weeks` rows.
        data class Bucket(val label: String, val start: Long, var sends: Int)
        val buckets = ArrayList<Bucket>(weeks)
        for (offset in (weeks - 1) downTo 0) {
            val start = addWeeks(thisWeekStart, -offset, cal)
            buckets.add(Bucket(weekKey(start, cal), start, 0))
        }
        // Index by the bucket's normalized week-start instant — the only thing we match logs against.
        val indexByStart = HashMap<Long, Int>()
        for ((i, b) in buckets.withIndex()) indexByStart[b.start] = i
        for (log in sendLogs) {
            val logWeekStart = weekStart(log.loggedAt, cal)
            if (logWeekStart > thisWeekStart) continue // don't count weeks after the current one
            val i = indexByStart[logWeekStart] ?: continue
            buckets[i].sends += 1
        }
        return buckets.map { VolumeBucket(it.label, it.start, it.sends) }
    }

    /** Sends & attempts per board angle, ascending by angle. */
    private fun angleDistribution(logs: List<SessionLog>): List<AngleCount> {
        val sendsByAngle = HashMap<Int, Int>()
        val attemptsByAngle = HashMap<Int, Int>()
        for (log in logs) {
            attemptsByAngle[log.angle] = (attemptsByAngle[log.angle] ?: 0) + maxOf(1, log.attempts)
            if (log.isSend) sendsByAngle[log.angle] = (sendsByAngle[log.angle] ?: 0) + 1
        }
        val angles = (sendsByAngle.keys + attemptsByAngle.keys).toSortedSet()
        return angles.map {
            AngleCount(it, sendsByAngle[it] ?: 0, attemptsByAngle[it] ?: 0)
        }
    }

    /**
     * Generic per-period roll-up: group logs by `key(loggedAt)`, tally sends + hardest send label, and
     * count sessions from [sessions] (one per period it started in) when supplied, else from distinct
     * `sessionId` among that period's logs.
     */
    private fun rollups(
        logs: List<SessionLog>,
        sessions: List<SessionSummary>,
        calendar: CalendarFactory,
        key: (Long, Calendar) -> String,
    ): List<PeriodRollup> {
        val cal = calendar.new()
        // Session counts per period (from the explicit session list, if given).
        val sessionCountByPeriod = HashMap<String, Int>()
        if (sessions.isNotEmpty()) {
            for (s in sessions) {
                val k = key(s.startedAt, cal)
                sessionCountByPeriod[k] = (sessionCountByPeriod[k] ?: 0) + 1
            }
        }

        val sends = HashMap<String, Int>()
        val hardest = HashMap<String, Pair<Double, String>>() // key -> (difficulty, label)
        val distinctSessionIds = HashMap<String, MutableSet<String>>()
        for (log in logs) {
            val k = key(log.loggedAt, cal)
            if (log.isSend) sends[k] = (sends[k] ?: 0) + 1
            if (log.isSend) {
                val cur = hardest[k]
                if (cur == null || log.difficulty > cur.first) hardest[k] = log.difficulty to log.gradeLabel
            }
            val sid = log.sessionId
            if (sid != null) distinctSessionIds.getOrPut(k) { HashSet() }.add(sid)
        }

        // Every period that has logs OR (when sessions are supplied) a session that started in it.
        val periods = (sends.keys + sessionCountByPeriod.keys).toSortedSet()
        return periods.map { k ->
            val sessionCount = if (sessions.isEmpty()) {
                distinctSessionIds[k]?.size ?: 0
            } else {
                sessionCountByPeriod[k] ?: 0
            }
            PeriodRollup(k, sessionCount, sends[k] ?: 0, hardest[k]?.second)
        }
    }

    // --- Calendar key helpers (epoch-millis based) -----------------------------------------------

    /** `"YYYY-MM"` for the calendar month containing [millis]. */
    private fun monthKey(millis: Long, cal: Calendar): String {
        cal.timeInMillis = millis
        val year = cal.get(Calendar.YEAR)
        val month = cal.get(Calendar.MONTH) + 1 // Calendar.MONTH is 0-based
        return "%04d-%02d".format(year, month)
    }

    /**
     * ISO-style `"YYYY-Www"` for the week containing [millis] (week-year so week 1 doesn't collide
     * across the new-year boundary). `getWeekYear()` is the calendar's own week-numbering year.
     */
    private fun weekKey(millis: Long, cal: Calendar): String {
        cal.timeInMillis = millis
        val weekYear = cal.weekYear
        val week = cal.get(Calendar.WEEK_OF_YEAR)
        return "%04d-W%02d".format(weekYear, week)
    }

    /** The start instant (millis, midnight) of the week containing [millis] (calendar's first weekday). */
    private fun weekStart(millis: Long, cal: Calendar): Long {
        cal.timeInMillis = millis
        cal.set(Calendar.DAY_OF_WEEK, cal.firstDayOfWeek)
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }

    /** [base] shifted by [weeks] calendar weeks (negative steps back), normalized to the week start. */
    private fun addWeeks(base: Long, weeks: Int, cal: Calendar): Long {
        cal.timeInMillis = base
        cal.add(Calendar.WEEK_OF_YEAR, weeks)
        return weekStart(cal.timeInMillis, cal)
    }
}
