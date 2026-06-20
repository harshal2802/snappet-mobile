package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit coverage for the pure "Your Climbs" gallery engine ([KilterCreatedGallery], P2): it's global
 * across layouts (NOT the old layout-scoped Mine), segments Draft/Saved/All, sorts three ways, joins the
 * user's OWN logbook status (Sent/Project/Attempt/Untried — never community signals), and filters by name
 * + facets. Ported from the iOS `KilterCreatedGalleryTests`. All pure — no device, no catalog (hand-built
 * rows).
 */
class KilterCreatedGalleryTest {

    private val G = KilterCreatedGallery

    // Distinct, ascending timestamps so "newest first" is unambiguous.
    private fun t(i: Int): Long = 1_700_000_000_000L + i * 60_000L

    private fun row(
        uuid: String,
        name: String = "Climb",
        setter: String = "You",
        layoutId: Int = 1,
        angle: Int = 40,
        grade: Double? = 17.0,
        source: String = "manual",
        valid: Boolean = true,
        at: Int = 0,
    ) = KilterCreatedGallery.CreatedRow(
        uuid = uuid, name = name, setterUsername = setter, layoutId = layoutId, angle = angle,
        predictedGrade = grade, source = source, isValid = valid, createdAt = t(at),
    )

    private fun log(uuid: String, status: KilterAscentStatus) =
        KilterCreatedGallery.LogRow(uuid, status)

    // region Global across layouts (the headline change from Mine)

    @Test fun globalAcrossLayoutsByDefault() {
        val created = listOf(row("a", layoutId = 1, at = 0), row("b", layoutId = 7, at = 1),
            row("c", layoutId = 99, at = 2))
        val items = G.items(created, emptyList())
        assertEquals(
            "climbs on every layout show — a board/layout facet, not a gate (unlike Mine)",
            setOf("a", "b", "c"), items.map { it.uuid }.toSet(),
        )
    }

    @Test fun layoutFacetRestrictsWhenSet() {
        val created = listOf(row("a", layoutId = 1, at = 0), row("b", layoutId = 7, at = 1))
        val items = G.items(created, emptyList(), layoutId = 7)
        assertEquals(listOf("b"), items.map { it.uuid })
    }

    // endregion

    // region Status segmentation (Draft / Saved / All)

    @Test fun statusSegmentation() {
        val created = listOf(
            row("valid1", valid = true, at = 0),
            row("draft1", valid = false, at = 1),
            row("valid2", valid = true, at = 2),
            row("draft2", valid = false, at = 3),
        )
        assertEquals(
            setOf("valid1", "draft1", "valid2", "draft2"),
            G.items(created, emptyList(), segment = KilterCreatedGallery.Segment.ALL).map { it.uuid }.toSet(),
        )
        assertEquals(
            "Saved = complete/valid climbs only",
            setOf("valid1", "valid2"),
            G.items(created, emptyList(), segment = KilterCreatedGallery.Segment.SAVED).map { it.uuid }.toSet(),
        )
        assertEquals(
            "Drafts = the invalid (incomplete) climbs",
            setOf("draft1", "draft2"),
            G.items(created, emptyList(), segment = KilterCreatedGallery.Segment.DRAFTS).map { it.uuid }.toSet(),
        )
    }

    @Test fun itemCarriesDraftFlag() {
        val created = listOf(row("d", valid = false, at = 0))
        assertTrue(G.items(created, emptyList()).first().isDraft)
    }

    // endregion

    // region Sort orders

    @Test fun recentlySetSortIsDefaultNewestFirst() {
        val created = listOf(row("old", at = 0), row("mid", at = 1), row("new", at = 2))
        assertEquals(listOf("new", "mid", "old"), G.items(created, emptyList()).map { it.uuid })
    }

    @Test fun gradeSortHardestFirstWithUngradedLast() {
        val created = listOf(
            row("v5", grade = 13.0, at = 0),
            row("v9", grade = 21.0, at = 1),
            row("ungraded", grade = null, at = 2),
            row("v7", grade = 17.0, at = 3),
        )
        val items = G.items(created, emptyList(), sort = KilterCreatedGallery.Sort.GRADE)
        assertEquals(
            "hardest first; ungraded sinks below every graded climb",
            listOf("v9", "v7", "v5", "ungraded"), items.map { it.uuid },
        )
    }

    @Test fun mostClimbedSortBySendCountNotAllLogRows() {
        // "manyAttempts" has 4 log rows but ZERO sends; "oneSend" has a single send. Ranking by SENDS
        // must put the real send first — a never-sent climb with many attempts can't outrank it.
        // (manyAttempts is the NEWEST, so under an all-log-rows rank it would have led.)
        val created = listOf(row("oneSend", at = 0), row("manyAttempts", at = 1))
        val logs = listOf(
            log("manyAttempts", KilterAscentStatus.ATTEMPT),
            log("manyAttempts", KilterAscentStatus.ATTEMPT),
            log("manyAttempts", KilterAscentStatus.ATTEMPT),
            log("manyAttempts", KilterAscentStatus.PROJECT),
            log("oneSend", KilterAscentStatus.SENT),
        )
        val items = G.items(created, logs, sort = KilterCreatedGallery.Sort.MOST_CLIMBED)
        assertEquals(
            "rank key is SEND count, not every log row — the sent climb leads despite fewer rows",
            listOf("oneSend", "manyAttempts"), items.map { it.uuid },
        )
        assertEquals(listOf(1, 0), items.map { it.sendCount })
        // logCount display is unchanged — it still counts all log rows.
        assertEquals(4, items.associate { it.uuid to it.logCount }["manyAttempts"])
    }

    @Test fun mostClimbedRanksByMoreSends() {
        val created = listOf(row("oneSend", at = 0), row("twoSends", at = 1))
        val logs = listOf(
            log("oneSend", KilterAscentStatus.SENT),
            log("twoSends", KilterAscentStatus.SENT),
            log("twoSends", KilterAscentStatus.FLASH),
        )
        val items = G.items(created, logs, sort = KilterCreatedGallery.Sort.MOST_CLIMBED)
        assertEquals("flash + sent both count as sends", listOf("twoSends", "oneSend"), items.map { it.uuid })
        assertEquals(listOf(2, 1), items.map { it.sendCount })
    }

    @Test fun mostClimbedTieBreaksOnRecency() {
        val created = listOf(row("older", at = 0), row("newer", at = 1))   // both 0 sends
        val items = G.items(created, emptyList(), sort = KilterCreatedGallery.Sort.MOST_CLIMBED)
        assertEquals(
            "equal send counts fall back to newest-first",
            listOf("newer", "older"), items.map { it.uuid },
        )
    }

    // endregion

    // region Own status join (Sent / Project / Attempt / Untried) — never community

    @Test fun ownStatusSentWhenAnySend() {
        assertEquals(
            KilterCreatedGallery.OwnStatus.SENT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.ATTEMPT), log("x", KilterAscentStatus.SENT))),
        )
        assertEquals(
            "flash counts as a send",
            KilterCreatedGallery.OwnStatus.SENT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.FLASH))),
        )
    }

    @Test fun ownStatusProjectWhenProjectLoggedButNoSend() {
        assertEquals(
            "any explicit project (no send) → Project",
            KilterCreatedGallery.OwnStatus.PROJECT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.ATTEMPT), log("x", KilterAscentStatus.PROJECT))),
        )
    }

    @Test fun ownStatusProjectOnlyNoAttempt() {
        assertEquals(
            KilterCreatedGallery.OwnStatus.PROJECT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.PROJECT))),
        )
    }

    @Test fun ownStatusAttemptWhenOnlyAttempts() {
        // Explicit, future-proof precedence: only attempts (no send, no project) → Attempt, NOT the old
        // "non-empty && not-send => Project" lump.
        assertEquals(
            KilterCreatedGallery.OwnStatus.ATTEMPT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.ATTEMPT))),
        )
        assertEquals(
            KilterCreatedGallery.OwnStatus.ATTEMPT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.ATTEMPT), log("x", KilterAscentStatus.ATTEMPT))),
        )
    }

    @Test fun ownStatusPrecedenceSendBeatsProjectBeatsAttempt() {
        assertEquals(
            KilterCreatedGallery.OwnStatus.SENT,
            G.ownStatus(listOf(
                log("x", KilterAscentStatus.ATTEMPT),
                log("x", KilterAscentStatus.PROJECT),
                log("x", KilterAscentStatus.SENT),
            )),
        )
        assertEquals(
            KilterCreatedGallery.OwnStatus.PROJECT,
            G.ownStatus(listOf(log("x", KilterAscentStatus.ATTEMPT), log("x", KilterAscentStatus.PROJECT))),
        )
    }

    @Test fun ownStatusUntriedWhenNoLogs() {
        assertEquals(KilterCreatedGallery.OwnStatus.UNTRIED, G.ownStatus(emptyList()))
    }

    @Test fun ownStatusIsJoinedPerCard() {
        val created = listOf(row("sent", at = 0), row("proj", at = 1), row("att", at = 2),
            row("untried", at = 3))
        val logs = listOf(
            log("sent", KilterAscentStatus.SENT),
            log("proj", KilterAscentStatus.PROJECT),
            log("att", KilterAscentStatus.ATTEMPT),
        )
        val byUuid = G.items(created, logs).associate { it.uuid to it.ownStatus }
        assertEquals(KilterCreatedGallery.OwnStatus.SENT, byUuid["sent"])
        assertEquals(KilterCreatedGallery.OwnStatus.PROJECT, byUuid["proj"])
        assertEquals(KilterCreatedGallery.OwnStatus.ATTEMPT, byUuid["att"])
        assertEquals(KilterCreatedGallery.OwnStatus.UNTRIED, byUuid["untried"])
    }

    /** A log row pointing at some OTHER climb must not bleed into this climb's own status. */
    @Test fun ownStatusIgnoresUnrelatedLogs() {
        val created = listOf(row("mine", at = 0))
        val logs = listOf(log("someone-elses-uuid", KilterAscentStatus.SENT))
        assertEquals(KilterCreatedGallery.OwnStatus.UNTRIED, G.items(created, logs).first().ownStatus)
    }

    /**
     * The climbUuid join is normalized (trim + lowercased) on BOTH sides, so a log uuid that differs from
     * the climb uuid only in case / surrounding whitespace still resolves — never silently Untried.
     */
    @Test fun ownStatusJoinNormalizesCaseAndWhitespace() {
        val created = listOf(row("ABC-123", at = 0))
        val logs = listOf(log("  abc-123  ", KilterAscentStatus.SENT))   // padded + lowercased — same climb
        val item = G.items(created, logs).first()
        assertEquals("case/whitespace-only differences still join",
            KilterCreatedGallery.OwnStatus.SENT, item.ownStatus)
        assertEquals(1, item.logCount)
        assertEquals(1, item.sendCount)
    }

    @Test fun mostClimbedJoinIsNormalized() {
        // The send rank must also see the normalized join (an upper-case climb uuid vs lower-case log).
        val created = listOf(row("Climb-UP", at = 0), row("untried", at = 1))
        val logs = listOf(log("climb-up", KilterAscentStatus.SENT))
        val items = G.items(created, logs, sort = KilterCreatedGallery.Sort.MOST_CLIMBED)
        assertEquals(listOf("Climb-UP", "untried"), items.map { it.uuid })
        assertEquals(1, items.first().sendCount)
    }

    // endregion

    // region Search + facet filters

    @Test fun searchFiltersByNameCaseInsensitive() {
        val created = listOf(
            row("a", name = "Crimp Ladder", at = 0),
            row("b", name = "Sloper Highway", at = 1),
            row("c", name = "Crimpy Traverse", at = 2),
        )
        val items = G.items(created, emptyList(), search = "  CRIMP ")
        assertEquals(
            "matches name substring, trimmed + case-insensitive",
            setOf("a", "c"), items.map { it.uuid }.toSet(),
        )
    }

    /** Search matches name OR setterUsername (legacy Mine filter parity), not name only. */
    @Test fun searchMatchesSetterName() {
        val created = listOf(
            row("a", name = "Crimp Ladder", setter = "Alice", at = 0),
            row("b", name = "Sloper Highway", setter = "Bob", at = 1),
            row("c", name = "Pinch Wall", setter = "Alice", at = 2),
        )
        assertEquals(
            "matches the setter name, case-insensitively",
            setOf("a", "c"), G.items(created, emptyList(), search = "alice").map { it.uuid }.toSet(),
        )
        // A term that's only in a name still matches; a term in neither matches nothing.
        assertEquals(setOf("b"), G.items(created, emptyList(), search = "sloper").map { it.uuid }.toSet())
        assertTrue(G.items(created, emptyList(), search = "zzz").isEmpty())
    }

    /**
     * The angle facet options come from the climbs' OWN distinct angles (global across layouts),
     * ascending — not the installed catalog, so an off-catalog angle stays reachable.
     */
    @Test fun angleFacetsAreDistinctClimbAnglesAscending() {
        val created = listOf(
            row("a", angle = 45, at = 0), row("b", angle = 25, at = 1),
            row("c", angle = 45, at = 2), row("d", angle = 60, at = 3),
        )
        assertEquals("distinct + ascending", listOf(25, 45, 60), G.angleFacets(created))
        assertTrue(G.angleFacets(emptyList()).isEmpty())
    }

    @Test fun angleAndSourceFacets() {
        val created = listOf(
            row("a", angle = 40, source = "manual", at = 0),
            row("b", angle = 25, source = "generated", at = 1),
            row("c", angle = 40, source = "generated", at = 2),
        )
        assertEquals(setOf("a", "c"), G.items(created, emptyList(), angle = 40).map { it.uuid }.toSet())
        assertEquals(setOf("b", "c"),
            G.items(created, emptyList(), source = "generated").map { it.uuid }.toSet())
        assertEquals(listOf("c"),
            G.items(created, emptyList(), angle = 40, source = "generated").map { it.uuid })
    }

    @Test fun provenanceDerivedFromSource() {
        val created = listOf(row("h", source = "manual", at = 0), row("g", source = "generated", at = 1))
        val byUuid = G.items(created, emptyList()).associate { it.uuid to it.provenance }
        assertEquals(KilterCreatedGallery.Provenance.HAND_SET, byUuid["h"])
        assertEquals(KilterCreatedGallery.Provenance.GENERATED, byUuid["g"])
    }

    @Test fun emptyWhenNoCreatedClimbs() {
        assertTrue(G.items(emptyList(), listOf(log("x", KilterAscentStatus.SENT))).isEmpty())
    }

    // endregion
}
