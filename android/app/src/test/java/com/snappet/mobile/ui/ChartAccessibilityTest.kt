package com.snappet.mobile.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #98: the spoken `contentDescription` builders for the suite's custom-drawn charts are pure, so
 * the wording a TalkBack user hears is locked down here — no Compose, no device.
 */
class ChartAccessibilityTest {

    private val week = listOf("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

    @Test fun weekBarSummaryLeadsWithActiveDaysAndTotal() {
        val s = ChartAccessibility.weekBarSummary("Last 7 days focus", listOf(0, 30, 0, 0, 55, 0, 0), "minute", week)
        assertTrue(s.contains("active 2 of 7 days"))
        assertTrue(s.contains("85 minutes total"))
        // Busiest day is Friday (index 4) with 55.
        assertTrue(s.contains("Busiest day Fri with 55 minutes"))
    }

    @Test fun weekBarSummaryHandlesAllZero() {
        val s = ChartAccessibility.weekBarSummary("Last 7 days focus", List(7) { 0 }, "minute", week)
        assertEquals("Last 7 days focus: no minutes in the last 7 days.", s)
    }

    @Test fun weekBarSummaryHandlesEmpty() {
        assertEquals("X: no data yet.", ChartAccessibility.weekBarSummary("X", emptyList(), "action"))
    }

    @Test fun weekBarSummarySingularUnit() {
        val s = ChartAccessibility.weekBarSummary("Actions", listOf(1, 0, 0), "action", listOf("Mon", "Tue", "Wed"))
        assertTrue(s.contains("1 action total"))
        assertTrue(s.contains("Busiest day Mon with 1 action."))
    }

    @Test fun boardSummaryReadsRolesInRouteOrder() {
        val counts = mapOf("start" to 2, "middle" to 4, "finish" to 1, "foot" to 3)
        val s = ChartAccessibility.boardSummary(counts)
        assertEquals("Climb with 10 holds: 2 starts, 4 hands, 1 finish, 3 foots.", s)
    }

    @Test fun boardSummaryOmitsAbsentRoles() {
        val s = ChartAccessibility.boardSummary(mapOf("start" to 1, "finish" to 1))
        assertEquals("Climb with 2 holds: 1 start, 1 finish.", s)
    }

    @Test fun boardSummaryEmpty() {
        assertEquals("Empty board, no holds set.", ChartAccessibility.boardSummary(emptyMap()))
    }

    @Test fun roleCountsTallyByName() {
        val counts = ChartAccessibility.roleCountsOf(listOf("start", "middle", "middle", "foot"))
        assertEquals(1, counts["start"])
        assertEquals(2, counts["middle"])
        assertEquals(1, counts["foot"])
    }
}
