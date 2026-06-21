package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * Locks the Android port of the Kilter P4 session-history contract — the pure [KilterHistoryModel]
 * (bucketing / scope / faceted filtering + stale recovery / adaptive-card facts / search) and
 * [KilterConsistency] (heatmap + calendar day buckets) behave deterministically. Mirrors the iOS
 * `KilterHistoryTests`. No emulator.
 */
class KilterHistoryModelTest {

    // A fixed clock + a UTC / Monday calendar so month/week bucketing is stable across CI time zones
    // (mirrors the iOS test's injected Gregorian-UTC-firstWeekday=Monday calendar).
    private val cal = KilterHistoryModel.CalendarFactory {
        Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            firstDayOfWeek = Calendar.MONDAY
            minimalDaysInFirstWeek = 4 // ISO-ish week-year, matches iOS yearForWeekOfYear
        }
    }
    private val now = 1_718_000_000_000L // 2024-06-10T07:33:20Z (epoch MILLIS)
    private val dayMs = 86_400_000L

    // MARK: - Builders

    private fun session(
        id: String, daysAgo: Int, angle: Int = 40, source: String = "ble",
        layoutId: Int? = 1, title: String? = null, active: Boolean = false, hasHR: Boolean = false,
    ): KilterHistoryModel.SessionItem {
        val start = now - daysAgo.toLong() * dayMs
        return KilterHistoryModel.SessionItem(
            id = id, startedAt = start, endedAt = if (active) null else start + 3_600_000L,
            angle = angle, source = source, layoutId = layoutId, title = title, hasHR = hasHR,
        )
    }

    private var logSeq = 0
    private fun log(
        sid: String?, grade: String, diff: Double, status: KilterAscentStatus,
        daysAgo: Int, name: String = "Climb", attempts: Int = 1,
    ): KilterHistoryModel.HistoryLog {
        val at = now - daysAgo.toLong() * dayMs
        return KilterHistoryModel.HistoryLog(
            climbUuid = "u-${logSeq++}", climbName = name, gradeLabel = grade, difficulty = diff,
            status = status, attempts = attempts, loggedAt = at, sessionId = sid,
        )
    }

    /** A log whose `loggedAt` is an EXACT instant (for the post-midnight bucketing case). */
    private fun logAt(
        sid: String?, grade: String, diff: Double, status: KilterAscentStatus,
        loggedAt: Long, name: String = "Climb",
    ) = KilterHistoryModel.HistoryLog(
        climbUuid = "u-${logSeq++}", climbName = name, gradeLabel = grade, difficulty = diff,
        status = status, attempts = 1, loggedAt = loggedAt, sessionId = sid,
    )

    private fun filters(facet: KilterHistoryModel.Facet, value: String) =
        KilterHistoryModel.Filters(selections = mapOf(facet to value))

    private fun logsBySession(logs: List<KilterHistoryModel.HistoryLog>): Map<String, List<KilterHistoryModel.HistoryLog>> =
        logs.mapNotNull { l -> l.sessionId?.let { it to l } }.groupBy({ it.first }, { it.second })

    // MARK: - Bucketing (month / week / all)

    @Test fun monthBucketingGroupsByCalendarMonth() {
        val a = "a"; val b = "b"; val c = "c"
        val sessions = listOf(session(a, 2), session(b, 5), session(c, 45)) // June, June, ~April/May
        val logs = listOf(
            log(a, "6a/V3", 18.0, KilterAscentStatus.SENT, 2),
            log(b, "6b/V4", 20.0, KilterAscentStatus.FLASH, 5),
            log(c, "5+/V2", 16.0, KilterAscentStatus.SENT, 45),
        )
        val model = KilterHistoryModel.build(sessions, logs, KilterHistoryModel.Scope.ALL,
            KilterHistoryModel.Filters(), now, cal)
        assertEquals(1, model.groups.size) // .all → single group
        val byMonth = KilterHistoryModel.group(sessions, logsBySession(logs),
            scope = KilterHistoryModel.Scope.MONTH, now = now, calendar = cal)
        assertEquals(2, byMonth.size)
        assertEquals(2, byMonth.first().rows.size) // newest month (June) has 2 sessions
    }

    @Test fun weekBucketingSplitsByWeek() {
        val byWeek = KilterHistoryModel.group(listOf(session("a", 1), session("b", 10)), emptyMap(),
            scope = KilterHistoryModel.Scope.WEEK, now = now, calendar = cal)
        assertEquals(2, byWeek.size) // sessions 9 days apart land in different weeks
    }

    @Test fun scopeWindowingKeepsOnlyInWindow() {
        val recent = session("r", 0)
        val old = session("o", 40)
        val week = KilterHistoryModel.inScope(listOf(recent, old), KilterHistoryModel.Scope.WEEK, now, cal)
        assertEquals(listOf(recent.id), week.map { it.id })
        val month = KilterHistoryModel.inScope(listOf(recent, old), KilterHistoryModel.Scope.MONTH, now, cal)
        assertEquals(listOf(recent.id), month.map { it.id })
        val all = KilterHistoryModel.inScope(listOf(recent, old), KilterHistoryModel.Scope.ALL, now, cal)
        assertEquals(setOf(recent.id, old.id), all.map { it.id }.toSet())
    }

    @Test fun activeSessionAlwaysInScope() {
        val live = session("live", 99, active = true)
        val week = KilterHistoryModel.inScope(listOf(live), KilterHistoryModel.Scope.WEEK, now, cal)
        assertEquals(listOf(live.id), week.map { it.id })
    }

    // MARK: - Roll-up headers

    @Test fun rollupSummaryCountsSessionsSendsAndHardest() {
        val a = "a"; val b = "b"
        val sessions = listOf(session(a, 1), session(b, 2))
        val logs = listOf(
            log(a, "6a/V3", 18.0, KilterAscentStatus.SENT, 1),
            log(a, "7a/V6", 24.0, KilterAscentStatus.FLASH, 1),
            log(b, "5+/V2", 16.0, KilterAscentStatus.PROJECT, 2),
        )
        assertEquals("2 sessions · 2 sent · hardest 7a/V6",
            KilterHistoryModel.rollupSummary(sessions, logsBySession(logs)))
    }

    @Test fun rollupSummaryDropsHardestWhenNothingSent() {
        val sessions = listOf(session("a", 1))
        val logs = listOf(log("a", "6a/V3", 18.0, KilterAscentStatus.PROJECT, 1))
        assertEquals("1 session · 0 sent",
            KilterHistoryModel.rollupSummary(sessions, logsBySession(logs)))
    }

    // MARK: - Faceted filtering

    @Test fun eachFacetFilter() {
        val a = "a"; val b = "b"
        val sessions = listOf(
            session(a, 1, angle = 40, source = "ble", layoutId = 1),
            session(b, 2, angle = 25, source = "manual", layoutId = 2),
        )
        val logs = listOf(
            log(a, "6a/V3", 18.0, KilterAscentStatus.SENT, 1),
            log(b, "5+/V2", 16.0, KilterAscentStatus.PROJECT, 2),
        )
        val names: (Int) -> String? = { if (it == 1) "Original" else "Homewall" }
        fun build(f: KilterHistoryModel.Filters): List<String> =
            KilterHistoryModel.build(sessions, logs, KilterHistoryModel.Scope.ALL, f, now, cal, names)
                .groups.flatMap { g -> g.rows.map { it.session.id } }
        assertEquals(listOf(a), build(filters(KilterHistoryModel.Facet.ANGLE, "40°")))
        assertEquals(listOf(b), build(filters(KilterHistoryModel.Facet.SOURCE, "Manual")))
        assertEquals(listOf(b), build(filters(KilterHistoryModel.Facet.BOARD, "Homewall")))
        assertEquals(listOf(a), build(filters(KilterHistoryModel.Facet.GRADE, "6a/V3")))
        assertEquals(listOf(b), build(filters(KilterHistoryModel.Facet.STATUS, "PROJECT")))
    }

    @Test fun combinedFacetsAreANDed() {
        val a = "a"; val b = "b"
        val sessions = listOf(
            session(a, 1, angle = 40, source = "ble"),
            session(b, 2, angle = 40, source = "manual"),
        )
        val logs = listOf(
            log(a, "6a/V3", 18.0, KilterAscentStatus.SENT, 1),
            log(b, "6a/V3", 18.0, KilterAscentStatus.SENT, 2),
        )
        val f = KilterHistoryModel.Filters(
            selections = mapOf(KilterHistoryModel.Facet.ANGLE to "40°", KilterHistoryModel.Facet.SOURCE to "BLE"))
        val ids = KilterHistoryModel.build(sessions, logs, KilterHistoryModel.Scope.ALL, f, now, cal)
            .groups.flatMap { g -> g.rows.map { it.session.id } }
        assertEquals(listOf(a), ids)
    }

    @Test fun staleFilterRecoveryFlag() {
        val sessions = listOf(session("a", 1, angle = 40))
        val logs = listOf(log("a", "6a/V3", 18.0, KilterAscentStatus.SENT, 1))
        val model = KilterHistoryModel.build(sessions, logs, KilterHistoryModel.Scope.ALL,
            filters(KilterHistoryModel.Facet.ANGLE, "70°"), now, cal)
        assertTrue(model.groups.isEmpty())
        assertTrue(model.isStaleFilter)
        val empty = KilterHistoryModel.build(emptyList(), emptyList(), KilterHistoryModel.Scope.ALL,
            KilterHistoryModel.Filters(), now, cal)
        assertFalse(empty.isStaleFilter)
    }

    @Test fun facetValuesComeFromFullSetNotFiltered() {
        val sessions = listOf(session("a", 1, angle = 40), session("b", 2, angle = 25))
        val model = KilterHistoryModel.build(sessions, emptyList(), KilterHistoryModel.Scope.ALL,
            filters(KilterHistoryModel.Facet.ANGLE, "40°"), now, cal)
        assertEquals(listOf("25°", "40°"), model.facetValues[KilterHistoryModel.Facet.ANGLE])
    }

    @Test fun searchMatchesTitleBoardAndClimbName() {
        val a = "a"; val b = "b"; val c = "c"
        val sessions = listOf(
            session(a, 1, layoutId = 1, title = "Comp prep"),
            session(b, 2, layoutId = 2),
            session(c, 3, layoutId = 1),
        )
        val logs = listOf(log(c, "6a/V3", 18.0, KilterAscentStatus.SENT, 3, name = "Moonwalk"))
        val names: (Int) -> String? = { if (it == 1) "Original" else "Homewall" }
        fun search(q: String): Set<String> =
            KilterHistoryModel.build(sessions, logs, KilterHistoryModel.Scope.ALL,
                KilterHistoryModel.Filters(search = q), now, cal, names)
                .groups.flatMap { g -> g.rows.map { it.session.id } }.toSet()
        assertEquals(setOf(a), search("comp"))     // title
        assertEquals(setOf(b), search("homewall")) // board name
        assertEquals(setOf(c), search("moon"))     // climb name
    }

    // MARK: - Adaptive card facts (one badge max)

    @Test fun defaultFactsAreSendsHardestDuration() {
        val s = session("s", 1)
        val logs = listOf(
            log(s.id, "6a/V3", 18.0, KilterAscentStatus.SENT, 1),
            log(s.id, "6b/V4", 20.0, KilterAscentStatus.SENT, 1),
        )
        val card = KilterHistoryModel.card(s, logs, priorHardestDifficulty = 25.0) // no PR
        assertEquals(
            listOf(KilterHistoryModel.CardFact.Kind.SENDS, KilterHistoryModel.CardFact.Kind.HARDEST,
                KilterHistoryModel.CardFact.Kind.DURATION),
            card.facts.map { it.kind })
        assertEquals("2", card.facts[0].value)
        assertEquals("6b/V4", card.facts[1].value)
        assertNull(card.badge)
    }

    @Test fun prBadgeWhenSessionBeatsPriorHardest() {
        val s = session("s", 1)
        val logs = listOf(log(s.id, "7a/V6", 24.0, KilterAscentStatus.SENT, 1))
        val card = KilterHistoryModel.card(s, logs, priorHardestDifficulty = 20.0)
        assertEquals(KilterHistoryModel.CardFact.Kind.PR_BADGE, card.badge?.kind)
        assertEquals("7a/V6", card.badge?.value)
    }

    @Test fun firstEverSendIsAPR() {
        val s = session("s", 1)
        val logs = listOf(log(s.id, "5+/V2", 16.0, KilterAscentStatus.SENT, 1))
        val card = KilterHistoryModel.card(s, logs, priorHardestDifficulty = null)
        assertEquals(KilterHistoryModel.CardFact.Kind.PR_BADGE, card.badge?.kind)
    }

    @Test fun flashRateBadgeWhenMajorityFlashed() {
        val s = session("s", 1)
        val logs = listOf(
            log(s.id, "6a/V3", 18.0, KilterAscentStatus.FLASH, 1),
            log(s.id, "6a/V3", 18.0, KilterAscentStatus.FLASH, 1),
        )
        val card = KilterHistoryModel.card(s, logs, priorHardestDifficulty = 30.0)
        assertEquals(KilterHistoryModel.CardFact.Kind.FLASH_RATE, card.badge?.kind)
        assertEquals("100%", card.badge?.value)
    }

    @Test fun projectsBadgeWhenNothingHotterApplies() {
        val s = session("s", 1)
        val logs = listOf(
            log(s.id, "6a/V3", 18.0, KilterAscentStatus.PROJECT, 1),
            log(s.id, "6b/V4", 20.0, KilterAscentStatus.PROJECT, 1),
        )
        val card = KilterHistoryModel.card(s, logs, priorHardestDifficulty = 30.0)
        assertEquals(KilterHistoryModel.CardFact.Kind.PROJECTS, card.badge?.kind)
        assertEquals("2", card.badge?.value)
    }

    @Test fun badgePriorityPRBeatsFlashBeatsProjects() {
        val s = session("s", 1)
        val logs = listOf(
            log(s.id, "7a/V6", 24.0, KilterAscentStatus.FLASH, 1),
            log(s.id, "6a/V3", 18.0, KilterAscentStatus.PROJECT, 1),
        )
        val card = KilterHistoryModel.card(s, logs, priorHardestDifficulty = 20.0)
        assertEquals(KilterHistoryModel.CardFact.Kind.PR_BADGE, card.badge?.kind)
    }

    @Test fun provenanceAndLiveFlags() {
        val ble = KilterHistoryModel.card(session("x", 1, source = "ble"), emptyList())
        assertEquals("BLE", ble.provenance.value)
        assertFalse(ble.isLive)
        val live = KilterHistoryModel.card(session("y", 1, source = "manual", active = true), emptyList())
        assertEquals("Manual", live.provenance.value)
        assertTrue(live.isLive)
    }

    @Test fun priorHardestBySessionIsChronologicalAndGlobal() {
        val s1 = "s1"; val s2 = "s2"; val s3 = "s3"
        val sessions = listOf(session(s1, 30), session(s2, 20), session(s3, 10))
        val logs = listOf(
            log(s1, "6a/V3", 18.0, KilterAscentStatus.SENT, 30),
            log(s2, "6c/V5", 22.0, KilterAscentStatus.SENT, 20),
            log(s3, "6b/V4", 20.0, KilterAscentStatus.SENT, 10),
        )
        val prior = KilterHistoryModel.priorHardestBySession(sessions, logsBySession(logs))
        assertNull(prior[s1])
        assertEquals(18.0, prior[s2]!!, 1e-9)
        assertEquals(22.0, prior[s3]!!, 1e-9) // running max from s2, not s1
    }

    // MARK: - Consistency surfaces

    @Test fun heatmapBucketsSendsByDayAndScalesIntensity() {
        val a = "a"; val b = "b"
        val sessions = listOf(session(a, 1), session(b, 3))
        val logs = listOf(
            log(a, "6a/V3", 18.0, KilterAscentStatus.SENT, 1),
            log(a, "6b/V4", 20.0, KilterAscentStatus.SENT, 1),
            log(b, "5+/V2", 16.0, KilterAscentStatus.SENT, 3),
        )
        val days = KilterConsistency.heatmap(sessions, logs, now, weeks = 8, calendar = cal)
        val active = days.filter { !it.isEmpty }
        assertEquals(2, active.size)
        val busiest = active.maxByOrNull { it.sends }
        assertEquals(2, busiest?.sends)
        assertEquals(1.0, busiest!!.intensity, 1e-9)
    }

    @Test fun monthDaysCoverWholeMonthAndDotActiveDays() {
        val sessions = listOf(session("a", 1))
        val logs = listOf(log("a", "6a/V3", 18.0, KilterAscentStatus.SENT, 1))
        val days = KilterConsistency.monthDays(sessions, logs, now, cal)
        assertEquals(30, days.size) // June has 30 days
        assertEquals(1, days.count { !it.isEmpty })
    }

    // MARK: - active session never renders a stale period header

    @Test fun activeSessionBucketsIntoCurrentPeriodNotStale() {
        val live = session("live", 40, active = true)
        val recent = session("recent", 1)
        val sessions = listOf(live, recent)

        val month = KilterHistoryModel.build(sessions, emptyList(), KilterHistoryModel.Scope.MONTH,
            KilterHistoryModel.Filters(), now, cal)
        assertEquals(1, month.groups.size)
        assertEquals(setOf(live.id, recent.id), month.groups[0].rows.map { it.session.id }.toSet())
        assertEquals(KilterHistoryModel.monthKey(now, cal), month.groups[0].id)

        val week = KilterHistoryModel.build(sessions, emptyList(), KilterHistoryModel.Scope.WEEK,
            KilterHistoryModel.Filters(), now, cal)
        assertEquals(1, week.groups.size)
        assertEquals(KilterHistoryModel.weekKey(now, cal), week.groups[0].id)
    }

    @Test fun inactiveSessionStillBucketsByItsOwnStart() {
        val byMonth = KilterHistoryModel.group(listOf(session("a", 1), session("b", 45)), emptyMap(),
            scope = KilterHistoryModel.Scope.MONTH, now = now, calendar = cal)
        assertEquals(2, byMonth.size)
    }

    // MARK: - consistency window-normalize + bucket-by-log-day + ad-hoc logs

    @Test fun heatmapNormalizesOverWindowNotAllLogs() {
        val inWin = "in"; val outWin = "out"
        val sessions = listOf(session(inWin, 1), session(outWin, 300))
        val logs = listOf(
            log(inWin, "6a/V3", 18.0, KilterAscentStatus.SENT, 1),
            log(outWin, "6a/V3", 18.0, KilterAscentStatus.SENT, 300),
            log(outWin, "6a/V3", 18.0, KilterAscentStatus.SENT, 300),
            log(outWin, "6a/V3", 18.0, KilterAscentStatus.SENT, 300),
            log(outWin, "6a/V3", 18.0, KilterAscentStatus.SENT, 300),
            log(outWin, "6a/V3", 18.0, KilterAscentStatus.SENT, 300),
        )
        val days = KilterConsistency.heatmap(sessions, logs, now, weeks = 8, calendar = cal)
        val busiest = days.filter { !it.isEmpty }.maxByOrNull { it.sends }
        assertEquals(1, busiest?.sends)
        assertEquals(1.0, busiest!!.intensity, 1e-9) // not crushed by the 5 out-of-window sends
    }

    @Test fun sendsBucketByLogDayIncludingPostMidnight() {
        val sid = "sess"
        val startDay = now - 2 * dayMs
        val startDay0 = KilterHistoryModel.startOfDay(startDay, cal)
        val justBeforeMidnight = startDay0 + 23 * 3_600_000L + 59 * 60_000L
        val afterMidnight = startDay0 + dayMs + 30 * 60_000L // 00:30 the next day
        val s = KilterHistoryModel.SessionItem(
            id = sid, startedAt = justBeforeMidnight, endedAt = afterMidnight,
            angle = 40, source = "ble", layoutId = 1, title = null, hasHR = false)
        val sendLog = logAt(sid, "6a/V3", 18.0, KilterAscentStatus.SENT, afterMidnight)

        val month = KilterConsistency.monthDays(listOf(s), listOf(sendLog), now, cal)
        val startKey = KilterHistoryModel.startOfDay(justBeforeMidnight, cal)
        val sendKey = KilterHistoryModel.startOfDay(afterMidnight, cal)
        assertNotEquals(startKey, sendKey)
        assertEquals(1, month.first { it.date == startKey }.sessions)
        assertEquals(0, month.first { it.date == startKey }.sends)
        assertEquals(1, month.first { it.date == sendKey }.sends)
    }

    @Test fun adHocSessionlessSendsAreCounted() {
        val adHoc = log(null, "6a/V3", 18.0, KilterAscentStatus.SENT, 1)
        val days = KilterConsistency.monthDays(emptyList(), listOf(adHoc), now, cal)
        val key = KilterHistoryModel.startOfDay(now - dayMs, cal)
        val cell = days.first { it.date == key }
        assertEquals(1, cell.sends)
        assertEquals(0, cell.sessions)
        assertFalse(cell.isEmpty)
    }

    // MARK: - deterministic tie-breaks

    @Test fun gradeFacetOrderTieBreaksByLabel() {
        val sessions = listOf(session("a", 1))
        val logs = listOf(
            log("a", "6a/V3", 20.0, KilterAscentStatus.SENT, 1, name = "x"),
            log("a", "6a+/V3", 20.0, KilterAscentStatus.SENT, 1, name = "y"),
        )
        repeat(8) {
            val model = KilterHistoryModel.build(sessions, logs, KilterHistoryModel.Scope.ALL,
                KilterHistoryModel.Filters(), now, cal)
            assertEquals(listOf("6a+/V3", "6a/V3"), model.facetValues[KilterHistoryModel.Facet.GRADE])
        }
    }

    @Test fun rollupHardestTieBreaksByLabel() {
        val sessions = listOf(session("a", 1))
        val logs = listOf(
            log("a", "7a/V6", 24.0, KilterAscentStatus.SENT, 1, name = "x"),
            log("a", "7a+/V6", 24.0, KilterAscentStatus.SENT, 1, name = "y"),
        )
        val out = (0 until 8).map { KilterHistoryModel.rollupSummary(sessions, logsBySession(logs)) }
        assertEquals(1, out.toSet().size)
    }

    @Test fun prAwardingDeterministicForIdenticalStartedAt() {
        val start = now
        fun s(id: String) = KilterHistoryModel.SessionItem(
            id = id, startedAt = start, endedAt = start + 3_600_000L,
            angle = 40, source = "ble", layoutId = 1, title = null, hasHR = false)
        val lo = "00000000-0000-0000-0000-000000000001"
        val hi = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        val logs = listOf(
            log(lo, "6a/V3", 18.0, KilterAscentStatus.SENT, 0),
            log(hi, "7a/V6", 24.0, KilterAscentStatus.SENT, 0),
        )
        repeat(8) {
            val prior = KilterHistoryModel.priorHardestBySession(listOf(s(hi), s(lo)), logsBySession(logs))
            assertNull(prior[lo]) // id-earliest has no prior
            assertEquals(18.0, prior[hi]!!, 1e-9)
        }
    }

    // MARK: - scope-aware stale-filter recovery

    @Test fun staleFilterSuggestsWidenScopeWhenMatchInAnotherPeriod() {
        val old = session("old", 40, angle = 25)
        val logs = listOf(log(old.id, "6a/V3", 18.0, KilterAscentStatus.SENT, 40))
        val model = KilterHistoryModel.build(listOf(old), logs, KilterHistoryModel.Scope.MONTH,
            filters(KilterHistoryModel.Facet.ANGLE, "25°"), now, cal)
        assertTrue(model.groups.isEmpty())
        assertEquals(KilterHistoryModel.StaleFilterRecovery.WIDEN_SCOPE, model.staleRecovery)
        assertTrue(model.isStaleFilter)
    }

    @Test fun staleFilterSuggestsClearWhenNoMatchAnywhere() {
        val s = session("s", 1, angle = 40)
        val logs = listOf(log(s.id, "6a/V3", 18.0, KilterAscentStatus.SENT, 1))
        val model = KilterHistoryModel.build(listOf(s), logs, KilterHistoryModel.Scope.MONTH,
            filters(KilterHistoryModel.Facet.ANGLE, "70°"), now, cal)
        assertTrue(model.groups.isEmpty())
        assertEquals(KilterHistoryModel.StaleFilterRecovery.CLEAR_FILTERS, model.staleRecovery)
    }

    @Test fun noRecoveryWhenScopeHasMatches() {
        val s = session("s", 1, angle = 40)
        val logs = listOf(log(s.id, "6a/V3", 18.0, KilterAscentStatus.SENT, 1))
        val model = KilterHistoryModel.build(listOf(s), logs, KilterHistoryModel.Scope.MONTH,
            filters(KilterHistoryModel.Facet.ANGLE, "40°"), now, cal)
        assertFalse(model.groups.isEmpty())
        assertEquals(KilterHistoryModel.StaleFilterRecovery.NONE, model.staleRecovery)
    }
}
