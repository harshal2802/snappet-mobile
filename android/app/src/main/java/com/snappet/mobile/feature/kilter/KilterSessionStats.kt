package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.hr.HRSample
import com.snappet.mobile.feature.kilter.hr.HRStats

/**
 * Pure, device-free stats core for one Kilter board session — grade pyramid, per-climb timeline,
 * send counts, duration, median time-on-climb, and an optional HR summary. Ported from the iOS
 * `KilterSessionStats` (`KilterSessionDetailView`'s data layer). No Room / Compose / Android deps,
 * so it runs in plain JVM unit tests.
 *
 * Inputs are [SessionLog] value rows (snapshots of [KilterLogEntry]); the renderer adapts the DB
 * rows into these. HR is optional — pass `hrSeries = emptyList()` and the HR fields stay null.
 */
object KilterSessionStats {

    /**
     * One logged climb, in pure value form (no Room types). `loggedAt` is epoch millis.
     *
     * `angle` and `sessionId` are additive (defaulted) so per-session callers stay unchanged; they
     * feed the all-time aggregator ([KilterAllTimeStats]) — `angle` the angle distribution, and
     * `sessionId` ([KilterSession.id], a String/UUID) the distinct-session roll-up count when no
     * explicit session list is supplied. Mirrors iOS `KilterClimbLog`'s `angle` / `sessionId` adds.
     */
    data class SessionLog(
        val climbUuid: String,
        val climbName: String,
        val gradeLabel: String,
        val difficulty: Double,
        val status: KilterAscentStatus,
        val attempts: Int,
        val loggedAt: Long,
        val angle: Int = 0,
        val sessionId: String? = null,
    ) {
        val isSend: Boolean get() = status.isSend
    }

    /**
     * One bar of the grade pyramid: a grade label, its representative difficulty (for sorting), and
     * the segmented counts at that grade.
     *
     * @property sends total sends at this grade (sent + flash) — the existing pyramid total, unchanged.
     * @property flashes of those [sends], how many were first-try flashes (a SUBSET of [sends]).
     * @property projects climbs left in the `.project` state at this grade (not counted in [sends]).
     * @property attemptsOnly climbs left in the `.attempt` state at this grade (not in [sends]/[projects]).
     */
    data class GradeCount(
        val gradeLabel: String,
        val difficulty: Double,
        val sends: Int,
        val flashes: Int = 0,
        val projects: Int = 0,
        val attemptsOnly: Int = 0,
    )

    /** One chronological row in the session timeline (one per logged climb). */
    data class TimelineItem(
        val index: Int,
        val climbUuid: String,
        val climbName: String,
        val gradeLabel: String,
        val status: KilterAscentStatus,
        val attempts: Int,
    )

    /** The computed session summary. */
    data class Stats(
        val totalClimbs: Int,
        val sends: Int,
        val projects: Int,
        val attemptsOnly: Int,
        val totalAttempts: Int,
        val hardestSendDifficulty: Double?,
        val hardestSendGrade: String?,
        val sendsPerHour: Double,
        val pyramid: List<GradeCount>,
        val timeline: List<TimelineItem>,
        /** Session duration in **seconds**. */
        val totalDurationSec: Double,
        /** HR summary over the session window, when an HR series was supplied. */
        val hr: HRStats?,
    )

    /**
     * @param logs the climbs logged during the session.
     * @param startMillis session start (epoch millis).
     * @param endMillis session end (epoch millis); for a still-open session pass "now".
     * @param hrSeries optional HR samples (session-relative seconds).
     * @param maxHR the user's max HR for zone bucketing.
     */
    fun make(
        logs: List<SessionLog>,
        startMillis: Long,
        endMillis: Long,
        hrSeries: List<HRSample> = emptyList(),
        maxHR: Int = com.snappet.mobile.feature.kilter.hr.HeartRateZone.DEFAULT_MAX_HR,
    ): Stats {
        val durationSec = ((endMillis - startMillis).coerceAtLeast(0L)) / 1000.0
        val sorted = logs.sortedBy { it.loggedAt }

        val sendLogs = sorted.filter { it.isSend }
        val sends = sendLogs.size
        val projects = sorted.count { it.status == KilterAscentStatus.PROJECT }
        val attemptsOnly = sorted.count { it.status == KilterAscentStatus.ATTEMPT }
        val totalAttempts = sorted.sumOf { maxOf(1, it.attempts) }  // each climb counts ≥ 1 try

        val hardest = sendLogs.maxByOrNull { it.difficulty }
        val sendsPerHour = if (durationSec > 0) sends / (durationSec / 3600.0) else 0.0

        // Grade pyramid: one row per grade with at least one SEND, easiest→hardest, each segmented
        // into flash/send/project/attempt. Shared with the all-time aggregator so segmentation is
        // defined once (mirrors iOS `segmentedPyramid`).
        val pyramid = segmentedPyramid(sorted, { it.gradeLabel }, { it.difficulty }, { it.status })

        val timeline = sorted.mapIndexed { i, log ->
            TimelineItem(
                index = i,
                climbUuid = log.climbUuid,
                climbName = log.climbName,
                gradeLabel = log.gradeLabel,
                status = log.status,
                attempts = log.attempts,
            )
        }

        val hr = if (hrSeries.isNotEmpty()) HRStats.make(hrSeries, maxHR) else null

        return Stats(
            totalClimbs = sorted.size,
            sends = sends,
            projects = projects,
            attemptsOnly = attemptsOnly,
            totalAttempts = totalAttempts,
            hardestSendDifficulty = hardest?.difficulty,
            hardestSendGrade = hardest?.gradeLabel,
            sendsPerHour = sendsPerHour,
            pyramid = pyramid,
            timeline = timeline,
            totalDurationSec = durationSec,
            hr = hr,
        )
    }

    /**
     * Build the segmented grade pyramid from any sequence of logs: one [GradeCount] per grade label
     * that recorded at least one SEND (the pyramid is a send-volume chart), easiest→hardest by the
     * grade's representative difficulty. Each row tallies `sends` (sent + flash), the `flashes`
     * subset, and `projects`/`attemptsOnly` at that grade.
     *
     * The representative `difficulty` (the sort key) is taken from a **sent** log at the grade — never
     * a `.project`/`.attempt`, whose float difficulty can differ from the sends and would mis-order the
     * pyramid. The first send seen at a grade fixes its sort key, overriding any value seeded by an
     * earlier non-send log. Shared by the per-session [make] and the all-time [KilterAllTimeStats] so
     * segmentation is defined once. Pure → unit-tested. Mirrors iOS `segmentedPyramid`.
     */
    fun <T> segmentedPyramid(
        logs: Iterable<T>,
        gradeLabel: (T) -> String,
        difficulty: (T) -> Double,
        status: (T) -> KilterAscentStatus,
    ): List<GradeCount> {
        val order = ArrayList<String>()
        val byGrade = HashMap<String, GradeCount>()
        // Whether a grade's representative difficulty has been pinned from a SEND yet.
        val difficultyFromSend = HashMap<String, Boolean>()
        for (log in logs) {
            val label = gradeLabel(log)
            if (byGrade[label] == null) {
                order.add(label)
                byGrade[label] = GradeCount(label, difficulty(log), sends = 0)
                difficultyFromSend[label] = false
            }
            val current = byGrade.getValue(label)
            val st = status(log)
            byGrade[label] = when (st) {
                KilterAscentStatus.FLASH -> current.copy(sends = current.sends + 1, flashes = current.flashes + 1)
                KilterAscentStatus.SENT -> current.copy(sends = current.sends + 1)
                KilterAscentStatus.PROJECT -> current.copy(projects = current.projects + 1)
                KilterAscentStatus.ATTEMPT -> current.copy(attemptsOnly = current.attemptsOnly + 1)
            }
            // Pin the representative difficulty to the FIRST send at this grade, overriding any value
            // seeded from an earlier non-send log so the sort key always comes from a real send.
            if (st.isSend && difficultyFromSend[label] == false) {
                byGrade[label] = byGrade.getValue(label).copy(difficulty = difficulty(log))
                difficultyFromSend[label] = true
            }
        }
        return order
            .mapNotNull { byGrade[it] }
            .filter { it.sends > 0 }
            .sortedBy { it.difficulty }
    }
}
