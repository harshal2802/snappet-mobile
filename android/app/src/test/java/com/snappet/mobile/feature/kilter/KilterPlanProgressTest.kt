package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.KilterRecommender.Goal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the persisted-plan progress logic ([KilterPlanProgress]) — the keystone that replaces the old
 * "re-derive done-ness from logs ∩ recommend()" path. The headline test
 * ([sendSectionPickStaysDoneAfterLog]) reproduces the original defect's shape: logging a send/project
 * pick must mark it done AND keep it in place. Port of the iOS `KilterPlanLogicTests`.
 */
class KilterPlanProgressTest {

    private fun item(uuid: String, diff: Double = 18.0) = KilterListItem(
        uuid = uuid, name = "Climb $uuid", setter = "S", difficulty = diff,
        gradeLabel = "6a/V3", quality = 2.5, ascents = 100,
    )

    private fun plan(vararg picks: Pair<String, Goal>) = KilterRecommender.Plan(
        picks = picks.map { KilterRecommender.Pick(item(it.first), it.second) },
        workingDifficulty = 18.0, workingGradeLabel = "6a/V3",
    )

    @Test fun itemsFromPlanPreserveOrderGoalsAndStartPending() {
        val items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND, "pr1" to Goal.PROJECT))
        assertEquals(listOf("w1", "s1", "pr1"), items.map { it.climbUuid })
        assertEquals(listOf(0, 1, 2), items.map { it.order })
        assertEquals(listOf(Goal.WARMUP, Goal.SEND, Goal.PROJECT), items.map { it.goal })
        assertTrue(items.all { it.status == KilterPlanItemStatus.PENDING })
    }

    @Test fun loggingSendMarksMatchingPickSentAndLeavesOthers() {
        val items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND))
        val after = KilterPlanProgress.applyingLog("s1", KilterAscentStatus.SENT, 1000L, items)
        assertEquals(KilterPlanItemStatus.SENT, after.first { it.climbUuid == "s1" }.status)
        assertEquals(1000L, after.first { it.climbUuid == "s1" }.completedAtMillis)
        assertEquals(KilterPlanItemStatus.PENDING, after.first { it.climbUuid == "w1" }.status)
    }

    /** THE REGRESSION: a send in the Send/Project section marks that very pick done and it STAYS put. */
    @Test fun sendSectionPickStaysDoneAfterLog() {
        val items = KilterPlanProgress.items(plan("s1" to Goal.SEND, "pr1" to Goal.PROJECT))
        val after = KilterPlanProgress.applyingLog("pr1", KilterAscentStatus.SENT, 1L, items)
        val pr = after.firstOrNull { it.climbUuid == "pr1" }
        assertNotNull("the project pick must still be present after sending it", pr)
        assertEquals(KilterPlanItemStatus.SENT, pr!!.status)
        assertEquals("no pick vanished or got swapped in", items.size, after.size)
        assertEquals("order is frozen", items.map { it.climbUuid }, after.map { it.climbUuid })
    }

    @Test fun attemptMarksAttemptedThenSendUpgrades() {
        var items = KilterPlanProgress.items(plan("s1" to Goal.SEND))
        items = KilterPlanProgress.applyingLog("s1", KilterAscentStatus.ATTEMPT, 1L, items)
        assertEquals(KilterPlanItemStatus.ATTEMPTED, items.first().status)
        items = KilterPlanProgress.applyingLog("s1", KilterAscentStatus.SENT, 2L, items)
        assertEquals(KilterPlanItemStatus.SENT, items.first().status)
    }

    @Test fun loggingOffPlanClimbLeavesPlanUnchanged() {
        val items = KilterPlanProgress.items(plan("s1" to Goal.SEND))
        val after = KilterPlanProgress.applyingLog("ZZZ", KilterAscentStatus.SENT, 1L, items)
        assertEquals(items, after)
    }

    @Test fun progressCountsDoneVsTotal() {
        var items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND, "pr1" to Goal.PROJECT))
        items = KilterPlanProgress.applyingLog("w1", KilterAscentStatus.FLASH, 1L, items)
        items = KilterPlanProgress.applyingLog("s1", KilterAscentStatus.ATTEMPT, 2L, items)
        assertEquals(2 to 3, KilterPlanProgress.progress(items))
    }

    @Test fun pendingClimbUuidsAreOrderedAndDropResolved() {
        var items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND, "pr1" to Goal.PROJECT))
        assertEquals(listOf("w1", "s1", "pr1"), KilterPlanProgress.pendingClimbUuids(items))
        items = KilterPlanProgress.applyingLog("s1", KilterAscentStatus.SENT, 1L, items)
        assertEquals(listOf("w1", "pr1"), KilterPlanProgress.pendingClimbUuids(items))
    }

    @Test fun nextPendingIsLowestOrderPending() {
        var items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND))
        assertEquals("w1", KilterPlanProgress.nextPending(items)?.climbUuid)
        items = KilterPlanProgress.applyingLog("w1", KilterAscentStatus.SENT, 1L, items)
        assertEquals("s1", KilterPlanProgress.nextPending(items)?.climbUuid)
    }

    @Test fun skippingDropsFromPendingButNotDone() {
        var items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND))
        val id = items.first { it.climbUuid == "w1" }.id
        items = KilterPlanProgress.skipping(id, items)
        assertEquals(KilterPlanItemStatus.SKIPPED, items.first { it.climbUuid == "w1" }.status)
        assertEquals(listOf("s1"), KilterPlanProgress.pendingClimbUuids(items))
        assertEquals(0, KilterPlanProgress.progress(items).first)
    }

    @Test fun allResolvedWhenNoPendingRemain() {
        var items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND))
        assertTrue(!KilterPlanProgress.allResolved(items))
        items = KilterPlanProgress.applyingLog("w1", KilterAscentStatus.SENT, 1L, items)
        val sid = items.first { it.climbUuid == "s1" }.id
        items = KilterPlanProgress.skipping(sid, items)
        assertTrue(KilterPlanProgress.allResolved(items))
    }

    @Test fun itemsCodecRoundTrips() {
        val items = KilterPlanProgress.items(plan("w1" to Goal.WARMUP, "s1" to Goal.SEND))
        val done = KilterPlanProgress.applyingLog("s1", KilterAscentStatus.SENT, 42L, items)
        val restored = KilterPlanItemsCodec.decode(KilterPlanItemsCodec.encode(done))
        assertEquals(done, restored)
    }
}
