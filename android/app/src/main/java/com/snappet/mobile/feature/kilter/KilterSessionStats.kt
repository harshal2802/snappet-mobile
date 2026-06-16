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

    /** One logged climb, in pure value form (no Room types). `loggedAt` is epoch millis. */
    data class SessionLog(
        val climbUuid: String,
        val climbName: String,
        val gradeLabel: String,
        val difficulty: Double,
        val status: KilterAscentStatus,
        val attempts: Int,
        val loggedAt: Long,
    ) {
        val isSend: Boolean get() = status.isSend
    }

    /** One bar of the grade pyramid: a grade label, its difficulty (for sorting), and send count. */
    data class GradeCount(val gradeLabel: String, val difficulty: Double, val sends: Int)

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

        // Grade pyramid: group sends by label; difficulty = last-seen send for that label; sort asc.
        val pyramid = sendLogs
            .groupBy { it.gradeLabel }
            .map { (label, rows) -> GradeCount(label, rows.last().difficulty, rows.size) }
            .sortedBy { it.difficulty }

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
}
