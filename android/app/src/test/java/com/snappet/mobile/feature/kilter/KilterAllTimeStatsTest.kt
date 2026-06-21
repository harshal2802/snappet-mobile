package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.KilterAllTimeStats.SessionSummary
import com.snappet.mobile.feature.kilter.KilterSessionStats.SessionLog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * Pure-logic tests for the **all-time** Kilter aggregator — no Room, no device. Synthetic [SessionLog]
 * / [SessionSummary] values feed [KilterAllTimeStats.make]. Mirrors the iOS `KilterAllTimeStatsTests`,
 * case-for-case, using the same UTC ISO-8601 (Monday-first, 4-day-minimal) calendar so the week/month
 * bucketing matches the Swift fixtures.
 */
class KilterAllTimeStatsTest {

    /** A UTC, Monday-first, ISO-week calendar factory — matches the Swift `Calendar(.iso8601)` UTC. */
    private val cal = KilterAllTimeStats.CalendarFactory {
        Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            firstDayOfWeek = Calendar.MONDAY
            minimalDaysInFirstWeek = 4
        }
    }

    /** Epoch millis for a y/m/d at UTC noon (readable fixtures, matching the iOS `date(_:_:_:)`). */
    private fun date(y: Int, m: Int, d: Int): Long {
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        c.clear()
        c.set(y, m - 1, d, 12, 0, 0) // Calendar months are 0-based
        return c.timeInMillis
    }

    /** A log builder with sensible defaults — only override what the case cares about. */
    private fun log(
        uuid: String,
        grade: String = "6a/V3",
        diff: Double = 15.0,
        status: KilterAscentStatus = KilterAscentStatus.SENT,
        attempts: Int = 1,
        angle: Int = 40,
        session: String? = null,
        at: Long,
    ) = SessionLog(
        climbUuid = uuid, climbName = uuid, gradeLabel = grade, difficulty = diff,
        status = status, attempts = attempts, loggedAt = at, angle = angle, sessionId = session,
    )

    // --- Empty -----------------------------------------------------------------------------------

    @Test fun emptyHistoryIsZeroed() {
        val s = KilterAllTimeStats.make(logs = emptyList(), nowMillis = date(2026, 6, 19), calendar = cal)
        assertEquals(KilterAllTimeStats.Stats.EMPTY, s)
        assertEquals(0, s.totalSends)
        assertEquals(0.0, s.sendRate, 0.0)
        assertEquals(0.0, s.flashRate, 0.0)
        assertNull(s.attemptsToSend)
        assertNull(s.maxGradeDifficulty)
        assertNull(s.climbingLevelDifficulty)
        assertTrue(s.maxGradeProgression.isEmpty())
        assertTrue(s.sendsPerWeek.isEmpty())
        assertTrue(s.angleDistribution.isEmpty())
        assertTrue(s.pyramid.isEmpty())
        assertTrue(s.monthRollups.isEmpty())
        assertTrue(s.weekRollups.isEmpty())
    }

    // --- Single session --------------------------------------------------------------------------

    @Test fun singleSessionCountsAndCeiling() {
        val d = date(2026, 6, 10)
        val logs = listOf(
            log("A", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.FLASH, at = d),
            log("B", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.SENT, attempts = 3, at = d),
            log("C", grade = "6c/V5", diff = 20.0, status = KilterAscentStatus.PROJECT, attempts = 4, at = d),
            log("D", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.ATTEMPT, attempts = 2, at = d),
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 12), calendar = cal)
        assertEquals(4, s.totalClimbsLogged)
        assertEquals(2, s.totalSends)                  // A flash + B sent
        assertEquals(4, s.distinctClimbs)
        assertEquals(1 + 3 + 4 + 2, s.totalAttempts)   // 10
        assertEquals(18.0, s.maxGradeDifficulty!!, 0.0) // hardest SEND is B (6b), not the C project
        assertEquals("6b/V4", s.maxGradeLabel)
    }

    // --- Multi-session ---------------------------------------------------------------------------

    @Test fun multiSessionDistinctClimbsAndTotals() {
        val s1 = "s1"; val s2 = "s2"
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, session = s1, at = date(2026, 5, 1)),
            log("A", status = KilterAscentStatus.SENT, session = s2, at = date(2026, 6, 1)), // same climb, later
            log("B", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.FLASH, session = s2, at = date(2026, 6, 1)),
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 5), calendar = cal)
        assertEquals(3, s.totalClimbsLogged)
        assertEquals(2, s.distinctClimbs)              // A and B
        assertEquals(3, s.totalSends)
    }

    // --- Send & flash rate -----------------------------------------------------------------------

    @Test fun sendRate() {
        val d = date(2026, 6, 1)
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, at = d),
            log("B", status = KilterAscentStatus.FLASH, at = d),
            log("C", status = KilterAscentStatus.ATTEMPT, at = d),
            log("D", status = KilterAscentStatus.PROJECT, at = d),
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = d, calendar = cal)
        assertEquals(0.5, s.sendRate, 0.0001) // 2 sends / 4 logged
    }

    @Test fun flashRate() {
        val d = date(2026, 6, 1)
        val logs = listOf(
            log("A", status = KilterAscentStatus.FLASH, at = d),
            log("B", status = KilterAscentStatus.FLASH, at = d),
            log("C", status = KilterAscentStatus.SENT, at = d),
            log("D", status = KilterAscentStatus.ATTEMPT, at = d), // not a send → not in denominator
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = d, calendar = cal)
        assertEquals(2.0 / 3.0, s.flashRate, 0.0001) // 2 flashes / 3 sends
    }

    // --- Attempts-to-send ------------------------------------------------------------------------

    @Test fun attemptsToSendAveragesOverSendsOnly() {
        val d = date(2026, 6, 1)
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, attempts = 2, at = d),
            log("B", status = KilterAscentStatus.FLASH, attempts = 1, at = d),
            log("C", status = KilterAscentStatus.SENT, attempts = 6, at = d),
            log("D", status = KilterAscentStatus.ATTEMPT, attempts = 99, at = d), // excluded: not sent
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = d, calendar = cal)
        assertEquals((2 + 1 + 6) / 3.0, s.attemptsToSend!!, 0.0001)
    }

    // --- Max-grade progression (chronological) ---------------------------------------------------

    @Test fun maxGradeProgressionPerMonthChronological() {
        val logs = listOf(
            log("A", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.SENT, at = date(2026, 4, 5)),
            log("B", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.SENT, at = date(2026, 4, 20)), // Apr 18
            log("C", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.SENT, at = date(2026, 5, 2)),
            log("D", grade = "7a/V6", diff = 22.0, status = KilterAscentStatus.SENT, at = date(2026, 5, 28)), // May 22
            log("E", grade = "6c/V5", diff = 20.0, status = KilterAscentStatus.PROJECT, at = date(2026, 6, 1)), // not a send
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 2), calendar = cal)
        assertEquals(listOf("2026-04", "2026-05"), s.maxGradeProgression.map { it.periodLabel })
        assertEquals(listOf(18.0, 22.0), s.maxGradeProgression.map { it.difficulty })
        assertEquals(listOf("6b/V4", "7a/V6"), s.maxGradeProgression.map { it.gradeLabel })
    }

    // --- Weekly volume buckets -------------------------------------------------------------------

    @Test fun weeklyVolumeBucketsZeroFilledAndOrdered() {
        val now = date(2026, 6, 17) // a Wednesday
        // Sends: 2 this week, 1 two weeks ago, none in between.
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, at = date(2026, 6, 16)),  // this week
            log("B", status = KilterAscentStatus.FLASH, at = date(2026, 6, 17)), // this week
            log("C", status = KilterAscentStatus.SENT, at = date(2026, 6, 3)),   // two weeks back
            log("D", status = KilterAscentStatus.ATTEMPT, at = date(2026, 6, 17)), // not a send
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = now, calendar = cal, weeklyVolumeWindow = 4)
        assertEquals(4, s.sendsPerWeek.size)
        // Oldest→newest, zero-filled in the middle, this week last.
        assertEquals(listOf(0, 1, 0, 2), s.sendsPerWeek.map { it.sends })
        // Strictly increasing window starts (chronological).
        val starts = s.sendsPerWeek.map { it.start }
        assertEquals(starts.sorted(), starts)
    }

    // --- Angle distribution ----------------------------------------------------------------------

    @Test fun angleDistributionSendsAndAttempts() {
        val d = date(2026, 6, 1)
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, attempts = 1, angle = 40, at = d),
            log("B", status = KilterAscentStatus.ATTEMPT, attempts = 3, angle = 40, at = d),
            log("C", status = KilterAscentStatus.FLASH, attempts = 1, angle = 25, at = d),
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = d, calendar = cal)
        assertEquals(listOf(25, 40), s.angleDistribution.map { it.angle }) // ascending
        val a25 = s.angleDistribution.first { it.angle == 25 }
        val a40 = s.angleDistribution.first { it.angle == 40 }
        assertEquals(1, a25.sends); assertEquals(1, a25.attempts)
        assertEquals(1, a40.sends)               // only A is a send at 40
        assertEquals(1 + 3, a40.attempts)        // A's 1 + B's 3
    }

    // --- Roll-ups --------------------------------------------------------------------------------

    @Test fun monthRollupsFromExplicitSessions() {
        val s1 = "s1"; val s2 = "s2"
        val sessions = listOf(
            SessionSummary(id = s1, startedAt = date(2026, 5, 2), endedAt = null, angle = 40),
            SessionSummary(id = s2, startedAt = date(2026, 6, 2), endedAt = null, angle = 40),
        )
        val logs = listOf(
            log("A", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.SENT, session = s1, at = date(2026, 5, 2)),
            log("B", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.FLASH, session = s2, at = date(2026, 6, 2)),
            log("C", grade = "6c/V5", diff = 20.0, status = KilterAscentStatus.ATTEMPT, session = s2, at = date(2026, 6, 3)),
        )
        val s = KilterAllTimeStats.make(logs = logs, sessions = sessions, nowMillis = date(2026, 6, 5), calendar = cal)
        assertEquals(listOf("2026-05", "2026-06"), s.monthRollups.map { it.periodLabel })
        val may = s.monthRollups[0]; val jun = s.monthRollups[1]
        assertEquals(1, may.sessions); assertEquals(1, may.sends)
        assertEquals("6a/V3", may.hardestGradeLabel)
        assertEquals(1, jun.sessions); assertEquals(1, jun.sends) // only B is a send in June
        assertEquals("6b/V4", jun.hardestGradeLabel)              // attempt C doesn't count
    }

    @Test fun rollupsFallBackToDistinctSessionIdWhenNoSessionList() {
        val s1 = "s1"; val s2 = "s2"
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, session = s1, at = date(2026, 6, 2)),
            log("B", status = KilterAscentStatus.SENT, session = s1, at = date(2026, 6, 2)), // same session
            log("C", status = KilterAscentStatus.SENT, session = s2, at = date(2026, 6, 3)), // different session, same month
            log("D", status = KilterAscentStatus.SENT, session = null, at = date(2026, 6, 4)), // ad-hoc → no session count
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 5), calendar = cal)
        assertEquals(1, s.monthRollups.size)
        assertEquals(2, s.monthRollups[0].sessions) // distinct s1, s2 (ad-hoc D excluded)
        assertEquals(4, s.monthRollups[0].sends)
    }

    @Test fun weekRollupsSplitByISOWeek() {
        val logs = listOf(
            log("A", status = KilterAscentStatus.SENT, session = "wa", at = date(2026, 6, 1)),  // week 23
            log("B", status = KilterAscentStatus.SENT, session = "wb", at = date(2026, 6, 10)), // week 24
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 12), calendar = cal)
        assertEquals(2, s.weekRollups.size)
        assertEquals(listOf(1, 1), s.weekRollups.map { it.sends })
    }

    // --- Segmented pyramid -----------------------------------------------------------------------

    @Test fun segmentedPyramidPerGrade() {
        val d = date(2026, 6, 1)
        val logs = listOf(
            log("A", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.FLASH, at = d),
            log("B", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.SENT, at = d),
            log("C", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.ATTEMPT, at = d),
            log("D", grade = "6c/V5", diff = 20.0, status = KilterAscentStatus.SENT, at = d),
            log("E", grade = "6c/V5", diff = 20.0, status = KilterAscentStatus.PROJECT, at = d),
            // A grade with ONLY a project (no send) must NOT appear — the pyramid is send-volume.
            log("F", grade = "7a/V6", diff = 22.0, status = KilterAscentStatus.PROJECT, at = d),
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = d, calendar = cal)
        assertEquals(listOf("6a/V3", "6c/V5"), s.pyramid.map { it.gradeLabel }) // easiest→hardest, 7a dropped

        val easy = s.pyramid[0]
        assertEquals(2, easy.sends)        // flash A + sent B (the existing pyramid total)
        assertEquals(1, easy.flashes)      // SUBSET: just A
        assertEquals(1, easy.attemptsOnly) // C
        assertEquals(0, easy.projects)

        val hard = s.pyramid[1]
        assertEquals(1, hard.sends)        // D
        assertEquals(0, hard.flashes)
        assertEquals(1, hard.projects)     // E
    }

    // --- Climbing level (recency window) ---------------------------------------------------------

    @Test fun climbingLevelSeededFromRecentSends() {
        // Old hard PR, then a stretch of consistent V4 sends — the level should track the recent V4s,
        // not the lone old V8/V11.
        val logs = ArrayList<SessionLog>()
        logs.add(log("PR", grade = "8a/V11", diff = 30.0, status = KilterAscentStatus.SENT, at = date(2025, 1, 1)))
        for (i in 0 until 6) {
            logs.add(log("r$i", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.SENT, at = date(2026, 6, 1 + i)))
        }
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 10), calendar = cal, climbingLevelWindow = 4)
        assertEquals(30.0, s.maxGradeDifficulty!!, 0.0)        // all-time ceiling still the old PR
        assertEquals(18.0, s.climbingLevelDifficulty!!, 0.0)   // recency window → the V4s
        assertEquals("6b/V4", s.climbingLevelLabel)
    }

    // --- Fix A: pyramid representative difficulty must come from a SEND ---------------------------

    @Test fun pyramidRepresentativeDifficultyComesFromSend() {
        val d = date(2026, 6, 1)
        val logs = listOf(
            // 6b/V4: a project + attempt logged FIRST with a bogus-high difficulty (50), then the real
            // send at 18. The send's 18 must be the row's sort key, so 6b sorts below the 7a send (22).
            log("p", grade = "6b/V4", diff = 50.0, status = KilterAscentStatus.PROJECT, at = d),
            log("a", grade = "6b/V4", diff = 50.0, status = KilterAscentStatus.ATTEMPT, at = d),
            log("s", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.SENT, at = d),
            log("h", grade = "7a/V6", diff = 22.0, status = KilterAscentStatus.SENT, at = d),
            log("e", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.SENT, at = d),
        )
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 2), calendar = cal)
        // Easiest→hardest by SEND difficulty: 6a(15) < 6b(18) < 7a(22). If 6b had kept the project's 50
        // it would sort last — this asserts it doesn't.
        assertEquals(listOf("6a/V3", "6b/V4", "7a/V6"), s.pyramid.map { it.gradeLabel })
        val sixB = s.pyramid.first { it.gradeLabel == "6b/V4" }
        assertEquals(18.0, sixB.difficulty, 0.0) // from the send, not the project's 50
        assertEquals(1, sixB.sends)              // segment counts unchanged
        assertEquals(1, sixB.projects)
        assertEquals(1, sixB.attemptsOnly)
    }

    // --- Fix B: climbingLevel determinism --------------------------------------------------------

    @Test fun climbingLevelDeterministicWithIdenticalTimestamps() {
        val d = date(2026, 6, 1) // one instant shared by every send
        val logs = ArrayList<SessionLog>()
        for (i in 0 until 5) logs.add(log("v4_$i", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.SENT, at = d))
        for (i in 0 until 3) logs.add(log("v3_$i", grade = "6a/V3", diff = 15.0, status = KilterAscentStatus.SENT, at = d))
        logs.add(log("v6", grade = "7a/V6", diff = 22.0, status = KilterAscentStatus.SENT, at = d))
        // Distinct climb UUIDs but a single timestamp: the recency window depends on the tie-break.
        val s1 = KilterAllTimeStats.make(logs = logs, nowMillis = date(2026, 6, 2), calendar = cal, climbingLevelWindow = 6)
        // Shuffle the input and re-run: a deterministic make must produce identical results.
        val s2 = KilterAllTimeStats.make(logs = logs.shuffled(), nowMillis = date(2026, 6, 2), calendar = cal, climbingLevelWindow = 6)
        assertEquals(s1.climbingLevelDifficulty, s2.climbingLevelDifficulty)
        assertEquals(s1.climbingLevelLabel, s2.climbingLevelLabel)
        // The label corresponds to the working bucket: difficulty rounds into the level.
        val lvl = s1.climbingLevelDifficulty!!
        val pickedDiff = logs.first { it.gradeLabel == s1.climbingLevelLabel }.difficulty
        assertEquals(Math.round(pickedDiff).toInt(), Math.round(lvl).toInt())
    }

    // --- Fix C: weekly bucketing across the year boundary ----------------------------------------

    @Test fun weeklyVolumeYearBoundaryWithLocalCalendar() {
        // Use a local-zone calendar (the user's default) — the boundary week likely began in late Dec.
        val localTz = TimeZone.getDefault()
        val localCal = KilterAllTimeStats.CalendarFactory {
            Calendar.getInstance(localTz).apply {
                firstDayOfWeek = Calendar.MONDAY
                minimalDaysInFirstWeek = 4
            }
        }
        // "now" = the first few days of a new year; the current week likely began in late December.
        val nowCal = Calendar.getInstance(localTz).apply { clear(); set(2026, 0, 2, 12, 0, 0) }
        val now = nowCal.timeInMillis
        // A send earlier in this SAME (boundary-straddling) week — 12:00 on the very first day of the
        // current week, possibly in the prior year. Its week-start matches the newest bucket's start.
        val weekStartCal = Calendar.getInstance(localTz).apply {
            timeInMillis = now
            firstDayOfWeek = Calendar.MONDAY
            minimalDaysInFirstWeek = 4
            set(Calendar.DAY_OF_WEEK, Calendar.MONDAY)
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        val inBoundaryWeek = weekStartCal.timeInMillis + 12L * 60 * 60 * 1000 // +12h into the week start
        val logs = listOf(
            log("boundary", grade = "6b/V4", diff = 18.0, status = KilterAscentStatus.SENT, at = inBoundaryWeek),
        )
        val weeks = 8
        val s = KilterAllTimeStats.make(logs = logs, nowMillis = now, calendar = localCal, weeklyVolumeWindow = weeks)
        assertEquals(weeks, s.sendsPerWeek.size)                  // exactly the window size
        assertEquals(1, s.sendsPerWeek.last().sends)             // counted in the most-recent bucket
        assertEquals(List(weeks - 1) { 0 }, s.sendsPerWeek.dropLast(1).map { it.sends })
        val starts = s.sendsPerWeek.map { it.start }
        assertEquals(starts.sorted(), starts)                    // oldest→newest
    }
}
