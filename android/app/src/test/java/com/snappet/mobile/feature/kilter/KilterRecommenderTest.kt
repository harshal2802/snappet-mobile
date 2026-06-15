package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Issue #93: JVM coverage for the pure session recommender — working-grade detection, the warm-up →
 * send → project spread, and the candidate window. Synthetic value types only, no Room/catalog/device.
 * Mirrors the iOS `KilterRecommenderTests`.
 */
class KilterRecommenderTest {

    private fun log(uuid: String, diff: Double, status: KilterAscentStatus, grade: String = "") =
        KilterLogEntry(
            climbUuid = uuid, climbName = uuid, angle = 40, difficulty = diff,
            gradeLabel = grade, status = status.name, createdAt = 0L,
        )

    private fun item(uuid: String, diff: Double, quality: Double = 2.0, ascents: Int = 100, grade: String = "g$diff") =
        KilterListItem(uuid = uuid, name = uuid, setter = "s", difficulty = diff,
            gradeLabel = grade, quality = quality, ascents = ascents)

    @Test fun workingGradeIsHardestBucketSentEnough() {
        val history = listOf(
            log("a", 17.0, KilterAscentStatus.SENT), log("b", 17.2, KilterAscentStatus.FLASH), // bucket 17 x2
            log("c", 19.0, KilterAscentStatus.SENT),                                            // bucket 19 x1
        )
        // 17 meets the threshold (2), 19 doesn't → working = 17.
        assertEquals(17.0, KilterRecommender.workingDifficulty(history, sendThreshold = 2)!!, 1e-9)
    }

    @Test fun workingGradeFallsBackToHardestSingleSend() {
        val history = listOf(log("a", 14.0, KilterAscentStatus.SENT), log("b", 18.0, KilterAscentStatus.SENT))
        // Neither bucket has 2 sends → hardest single send bucket = 18.
        assertEquals(18.0, KilterRecommender.workingDifficulty(history, sendThreshold = 2)!!, 1e-9)
    }

    @Test fun attemptsAndProjectsDontCountTowardWorkingGrade() {
        val history = listOf(
            log("a", 20.0, KilterAscentStatus.ATTEMPT), log("b", 20.0, KilterAscentStatus.PROJECT),
        )
        assertNull(KilterRecommender.workingDifficulty(history))
    }

    @Test fun allocationSumsToTarget() {
        for (t in 3..12) {
            val a = KilterRecommender.allocation(t)
            assertEquals(t, a.warmup + a.send + a.project)
            assertTrue(a.warmup >= 1 && a.send >= 1 && a.project >= 1)
        }
    }

    @Test fun planSpreadsWarmupSendProjectAroundWorkingGrade() {
        val history = listOf(
            log("w1", 16.0, KilterAscentStatus.SENT), log("w2", 16.0, KilterAscentStatus.SENT), // working 16
        )
        // A dense pool around 16.
        val candidates = (12..18).flatMap { g ->
            (0..2).map { item("c$g-$it", g.toDouble(), quality = (3 - it).toDouble()) }
        }
        val plan = KilterRecommender.recommend(history, candidates, anchor = 16.0,
            options = KilterRecommender.Options(targetCount = 6))

        assertFalse(plan.isEmpty)
        // Each goal is populated, and warm-ups are easier than the project.
        val warmups = plan.picks(KilterRecommender.Goal.WARMUP)
        val projects = plan.picks(KilterRecommender.Goal.PROJECT)
        assertTrue(warmups.isNotEmpty())
        assertTrue(projects.isNotEmpty())
        assertTrue(warmups.all { it.item.difficulty < 16.0 })
        assertTrue(projects.all { it.item.difficulty > 16.0 })
        // Display order is warm-up → send → project.
        val goals = plan.picks.map { it.goal }
        assertEquals(goals.sortedBy { it.ordinal }, goals)
    }

    @Test fun sendGoalPrefersUnsentClimbs() {
        val history = listOf(
            log("w1", 16.0, KilterAscentStatus.SENT), log("w2", 16.0, KilterAscentStatus.SENT),
            log("already", 16.0, KilterAscentStatus.SENT),
        )
        val candidates = listOf(item("already", 16.0, quality = 3.0), item("fresh", 16.0, quality = 1.0))
        val plan = KilterRecommender.recommend(history, candidates, anchor = 16.0,
            options = KilterRecommender.Options(targetCount = 6, preferUnsent = true))
        // Even though "already" ranks higher by quality, preferUnsent surfaces "fresh" for the send slot.
        assertTrue(plan.picks(KilterRecommender.Goal.SEND).any { it.item.uuid == "fresh" })
    }

    @Test fun coldStartUsesMedianCandidate() {
        // No history → anchors on the median candidate difficulty so a new climber still gets a spread.
        val candidates = (10..20).map { item("c$it", it.toDouble()) }
        val plan = KilterRecommender.recommend(emptyList(), candidates)
        assertNull(plan.workingDifficulty)
        assertFalse(plan.isEmpty)
    }

    @Test fun deterministicForSameInput() {
        val history = listOf(log("a", 16.0, KilterAscentStatus.SENT), log("b", 16.0, KilterAscentStatus.SENT))
        val candidates = (12..18).map { item("c$it", it.toDouble()) }
        val one = KilterRecommender.recommend(history, candidates, anchor = 16.0)
        val two = KilterRecommender.recommend(history, candidates, anchor = 16.0)
        assertEquals(one.picks.map { it.item.uuid }, two.picks.map { it.item.uuid })
    }

    @Test fun candidateWindowSpansAllBands() {
        val (lo, hi) = KilterRecommender.candidateWindow(16.0)
        // bands reach w-4 … w+2 → window must cover 11.5 … 18.5.
        assertEquals(11.5, lo, 1e-9)
        assertEquals(18.5, hi, 1e-9)
    }
}
