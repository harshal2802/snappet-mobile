package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/**
 * Pure-logic coverage for **On the Board** (Kilter Improvement P5): the per-climb-per-session dedup, the
 * day/session grouping + roll-ups, the status join (lit-only vs attempt vs sent, by normalized uuid), the
 * recent-rail ordering, and the deterministic tie-breaks. No Room / no device — the dedup/grouping/join all
 * live in the pure [KilterOnTheBoard] helper. Mirrors the iOS `KilterOnTheBoardTests`.
 */
class KilterOnTheBoardTest {

    private val zone: ZoneId = ZoneId.of("UTC")
    private val session = "session-A"

    /** A lit event. `at` is epoch SECONDS (mirrors the iOS `timeIntervalSince1970` cases); converted to ms. */
    private fun litEvent(
        uuid: String,
        name: String = "Climb",
        grade: String = "6a/V3",
        angle: Int = 40,
        layout: Int = 1,
        size: Int = 10,
        at: Long,
        connected: Boolean = true,
        session: String? = null,
    ) = KilterOnTheBoard.LitEvent(
        climbUuid = uuid, climbName = name, gradeLabel = grade, angle = angle,
        layoutId = layout, sizeId = size, litAt = at * 1000L, wasConnected = connected, sessionId = session,
    )

    private fun log(uuid: String, status: KilterAscentStatus) = KilterOnTheBoard.LogRow(uuid, status)

    // MARK: - Dedup (same climb + session → one row)

    @Test fun dedup_collapsesSameClimbSameSession_keepingNewestLitAt() {
        val events = listOf(
            litEvent("abc", at = 100, session = session),
            litEvent("abc", at = 300, session = session),   // newest light
            litEvent("abc", at = 200, session = session),
        )
        val deduped = KilterOnTheBoard.deduped(events)
        assertEquals("one climb lit thrice in a session is ONE row", 1, deduped.size)
        assertEquals("the surviving row carries the newest light time", 300_000L, deduped.first().litAt)
    }

    @Test fun dedup_keepsSameClimbInDifferentSessionsSeparate() {
        val events = listOf(
            litEvent("abc", at = 100, session = session),
            litEvent("abc", at = 200, session = "session-B"),
            litEvent("abc", at = 300, session = null),   // out-of-session light is its own bucket
        )
        assertEquals("the same climb across sessions stays separate rows", 3,
            KilterOnTheBoard.deduped(events).size)
    }

    @Test fun dedup_normalizesUuidForKey() {
        val events = listOf(
            litEvent("ABC ", at = 100, session = session),
            litEvent("abc", at = 200, session = session),
        )
        assertEquals("casing/whitespace must not split one climb into two", 1,
            KilterOnTheBoard.deduped(events).size)
    }

    @Test fun dedup_collapsesRepeatedNoSessionLightsToOneRow() {
        val events = listOf(
            litEvent("abc", at = 100, session = null),
            litEvent("abc", at = 300, session = null),   // newest no-session light
            litEvent("abc", at = 200, session = null),
        )
        val deduped = KilterOnTheBoard.deduped(events)
        assertEquals("repeated no-session lights of one climb are ONE row", 1, deduped.size)
        assertEquals("the surviving no-session row carries the newest light time",
            300_000L, deduped.first().litAt)
    }

    // MARK: - Deterministic tie-break (identical litAt in the same climb+session bucket)

    @Test fun tieBreak_onIdenticalLitAt_prefersConnected_deterministically() {
        val connected = litEvent("abc", at = 100, connected = true, session = session)
        val intentOnly = litEvent("abc", at = 100, connected = false, session = session)
        // Either input order yields the connected row — a total, input-order-independent order.
        assertEquals(true, KilterOnTheBoard.deduped(listOf(intentOnly, connected)).first().wasConnected)
        assertEquals(true, KilterOnTheBoard.deduped(listOf(connected, intentOnly)).first().wasConnected)
    }

    @Test fun tieBreak_onIdenticalLitAtAndConnected_fallsToSteeperAngle() {
        // Distinct climbs at the same instant — recent() orders them by the tie-break, not input order.
        val steep = litEvent("steep", angle = 50, at = 100, connected = true, session = session)
        val shallow = litEvent("shallow", angle = 30, at = 100, connected = true, session = session)
        assertEquals("steeper angle sorts first on an identical instant", listOf("steep", "shallow"),
            KilterOnTheBoard.recent(listOf(shallow, steep)).map { it.event.climbUuid })
        assertEquals("…and the order is input-independent", listOf("steep", "shallow"),
            KilterOnTheBoard.recent(listOf(steep, shallow)).map { it.event.climbUuid })
    }

    // MARK: - Status join

    @Test fun statusJoin_sentBeatsAttemptBeatsLit() {
        val logs = listOf(
            log("sent-climb", KilterAscentStatus.SENT),
            log("attempt-climb", KilterAscentStatus.ATTEMPT),
            log("project-climb", KilterAscentStatus.PROJECT),
        )
        assertEquals(KilterOnTheBoard.Status.SENT, KilterOnTheBoard.status("sent-climb", logs))
        assertEquals(KilterOnTheBoard.Status.ATTEMPT, KilterOnTheBoard.status("attempt-climb", logs))
        // A project-only climb reads as "lit" (worked on the wall, not sent, not a plain attempt).
        assertEquals(KilterOnTheBoard.Status.LIT, KilterOnTheBoard.status("project-climb", logs))
        // A lit-only climb with no log at all is "lit".
        assertEquals(KilterOnTheBoard.Status.LIT, KilterOnTheBoard.status("never-logged", logs))
    }

    @Test fun statusJoin_flashCountsAsSent_andIsUuidNormalized() {
        val logs = listOf(log("ABC", KilterAscentStatus.FLASH))
        assertEquals("a flash is a send; the join normalizes the uuid",
            KilterOnTheBoard.Status.SENT, KilterOnTheBoard.status("abc ", logs))
    }

    @Test fun statusJoin_sendStickyAcrossManyAttempts() {
        val logs = listOf(
            log("abc", KilterAscentStatus.ATTEMPT),
            log("abc", KilterAscentStatus.ATTEMPT),
            log("abc", KilterAscentStatus.SENT),
        )
        assertEquals("any send anywhere on the climb wins over earlier attempts",
            KilterOnTheBoard.Status.SENT, KilterOnTheBoard.status("abc", logs))
    }

    // MARK: - Grouping + roll-ups

    @Test fun grouping_bucketsByDayAndSession_withRollups() {
        val now = 1_000_000L                 // a fixed clock (epoch seconds)
        val dayA = now
        val dayB = dayA - 86_400             // the day before
        val events = listOf(
            litEvent("a1", at = dayA, session = "sA"),
            litEvent("a2", at = dayA + 60, session = "sA"),
            litEvent("b1", at = dayB, session = "sB"),
        )
        val logs = listOf(log("a1", KilterAscentStatus.SENT))
        val model = KilterOnTheBoard.build(events, logs, nowMillis = now * 1000L, zone = zone)

        assertEquals("two day/session buckets", 2, model.groups.size)
        // Newest group first (today's session A).
        val today = model.groups[0]
        assertEquals(2, today.rows.size)
        assertEquals("roll-up counts climbs worked + sends", "2 lit · 1 sent", today.summary)
        // Rows within a group are newest-first.
        assertEquals("a2", today.rows.first().event.climbUuid)
    }

    @Test fun groupHeadline_prefersBoardNameElseAngle() {
        val now = 2_000_000L
        val events = listOf(litEvent("a1", angle = 45, layout = 7, at = now, session = session))
        // With a layout name resolver → "Today · <board>".
        val named = KilterOnTheBoard.build(
            events, emptyList(), nowMillis = now * 1000L, zone = zone,
            layoutName = { if (it == 7) "BetaBoulders" else null },
        )
        assertEquals("Today · BetaBoulders", named.groups.first().headline)
        // Without a resolver → falls back to the dominant angle.
        val unnamed = KilterOnTheBoard.build(events, emptyList(), nowMillis = now * 1000L, zone = zone)
        assertEquals("Today · 45°", unnamed.groups.first().headline)
    }

    @Test fun heroCount_distinctClimbsOverDedupedSet() {
        val events = listOf(
            litEvent("a", at = 100, session = session),
            litEvent("a", at = 200, session = session),   // same climb, deduped away from the count
            litEvent("b", at = 300, session = session),
        )
        val model = KilterOnTheBoard.build(events, emptyList(), nowMillis = 400_000L, zone = zone)
        assertEquals("hero counts distinct climbs, not lit events", 2, model.climbsWorked)
    }

    // MARK: - Filtering

    @Test fun statusFacetFilter_narrowsRows_butChipRailStaysFull() {
        val now = 3_000_000L
        val t = now
        val events = listOf(
            litEvent("sent", at = t, session = session),
            litEvent("lit", at = t - 10, session = session),
        )
        val logs = listOf(log("sent", KilterAscentStatus.SENT))
        val model = KilterOnTheBoard.build(
            events, logs,
            selections = mapOf(KilterOnTheBoard.Facet.STATUS to KilterOnTheBoard.statusToken(KilterOnTheBoard.Status.SENT)),
            nowMillis = now * 1000L, zone = zone,
        )
        val allRows = model.groups.flatMap { it.rows }
        assertEquals("only the sent row survives the filter", listOf("sent"),
            allRows.map { it.event.climbUuid })
        // The facet rail still shows BOTH status chips (built pre-filter).
        assertEquals(
            setOf(
                KilterOnTheBoard.statusToken(KilterOnTheBoard.Status.LIT),
                KilterOnTheBoard.statusToken(KilterOnTheBoard.Status.SENT),
            ),
            (model.facetValues[KilterOnTheBoard.Facet.STATUS] ?: emptyList()).toSet(),
        )
    }

    // MARK: - Recent rail ordering

    @Test fun recentRail_isDedupedNewestFirstAndCapped() {
        val events = listOf(
            litEvent("a", at = 100, session = session),
            litEvent("a", at = 500, session = session),   // dedups; newest light 500
            litEvent("b", at = 300, session = session),
            litEvent("c", at = 400, session = session),
        )
        val rail = KilterOnTheBoard.recent(events, limit = 2)
        assertEquals("deduped, newest-first (a@500, c@400), capped at the limit", listOf("a", "c"),
            rail.map { it.event.climbUuid })
    }

    @Test fun recentRail_joinsStatus() {
        val events = listOf(litEvent("a", at = 100, session = session))
        val logs = listOf(log("a", KilterAscentStatus.SENT))
        assertEquals(KilterOnTheBoard.Status.SENT, KilterOnTheBoard.recent(events, logs).first().status)
    }

    @Test fun recentRail_emptyAndZeroLimit() {
        assertTrue(KilterOnTheBoard.recent(emptyList()).isEmpty())
        assertTrue(KilterOnTheBoard.recent(
            listOf(litEvent("a", at = 100, session = session)), limit = 0).isEmpty())
    }
}
