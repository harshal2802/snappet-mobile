package com.snappet.mobile.feature.kilter

import com.snappet.mobile.feature.kilter.KilterRecommender.Goal
import com.snappet.mobile.feature.kilter.KilterRecommender.Mix
import com.snappet.mobile.feature.kilter.KilterRecommender.Options
import com.snappet.mobile.feature.kilter.KilterRecommender.Strategy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS selection-strategy tests (PR 07/08 + the working-grade-label combined-review fix). */
class KilterRecommenderStrategyTest {

    private fun item(uuid: String, diff: Double, grade: String = "Vx") =
        KilterListItem(uuid = uuid, name = "C", setter = "S", difficulty = diff, gradeLabel = grade, quality = 2.5, ascents = 100)

    private fun pool(): List<KilterListItem> =
        (14..22).flatMap { d -> (0..3).map { i -> item("c$d-$i", d.toDouble()) } }

    @Test fun weightedAllocationLeansAndSumsToTarget() {
        val a = KilterRecommender.allocation(5, Mix(2.0, 1.0, 2.0))
        assertEquals(5, a.warmup + a.send + a.project)
        assertTrue(a.warmup >= 1 && a.send >= 1 && a.project >= 1)
        assertTrue("project-leaning mix gives project >= send", a.project >= a.send)
    }

    @Test fun zeroWeightGoalIsDropped() {
        val a = KilterRecommender.allocation(6, Mix(2.0, 4.0, 0.0))
        assertEquals(0, a.project)
        assertEquals(6, a.warmup + a.send)
        assertTrue(a.send > a.warmup)
    }

    @Test fun balancedDefaultUnchangedByNullMix() {
        for (t in 1..12) {
            val viaNull = KilterRecommender.recommend(emptyList(), pool(), anchor = 18.0, options = Options(targetCount = t, mix = null))
            val viaDefault = KilterRecommender.recommend(emptyList(), pool(), anchor = 18.0, options = Options(targetCount = t))
            assertEquals("t=$t", viaDefault.picks.map { it.item.uuid }, viaNull.picks.map { it.item.uuid })
        }
    }

    @Test fun everyStrategyMixAllocatesCleanlyAcrossLengths() {
        for (s in Strategy.entries) {
            val mix = KilterRecommender.config(s).mix ?: continue
            for (t in 3..12) {
                val a = KilterRecommender.allocation(t, mix)
                assertEquals("$s @$t sums", t, a.warmup + a.send + a.project)
                assertTrue(a.warmup >= 0 && a.send >= 0 && a.project >= 0)
                if (mix.warmup > 0) assertTrue("$s @$t warmup>=1", a.warmup >= 1)
                if (mix.send > 0) assertTrue("$s @$t send>=1", a.send >= 1)
                if (mix.project > 0) assertTrue("$s @$t project>=1", a.project >= 1)
            }
        }
    }

    @Test fun everyStrategyConfigIsCoherent() {
        for (s in Strategy.entries) {
            val c = KilterRecommender.config(s)
            assertTrue(c.targetCount >= 3)
            if (s == Strategy.BALANCED) assertNull(c.mix) else assertTrue(c.mix != null)
        }
    }

    @Test fun rerollChangesPicksButKeepsCountAndGoals() {
        val base = KilterRecommender.recommend(emptyList(), pool(), anchor = 18.0, options = Options(rerollSeed = 0))
        val shuffled = KilterRecommender.recommend(emptyList(), pool(), anchor = 18.0, options = Options(rerollSeed = 3))
        assertEquals(base.picks.size, shuffled.picks.size)
        assertEquals(base.picks.map { it.goal }, shuffled.picks.map { it.goal })
        assertNotEquals(base.picks.map { it.item.uuid }, shuffled.picks.map { it.item.uuid })
        val again = KilterRecommender.recommend(emptyList(), pool(), anchor = 18.0, options = Options(rerollSeed = 3))
        assertEquals("deterministic per seed", shuffled.picks.map { it.item.uuid }, again.picks.map { it.item.uuid })
    }

    @Test fun workingGradeLabelIsDetectedGradeNotOffsetAnchor() {
        val history = (0..1).map {
            KilterLogEntry(climbUuid = "h$it", climbName = "H", angle = 40, difficulty = 18.0,
                gradeLabel = "V5", status = KilterAscentStatus.SENT.name, createdAt = it.toLong())
        }
        val candidates = (16..22).flatMap { d -> (0..2).map { i -> item("c$d-$i", d.toDouble(), grade = if (d == 20) "V7" else "Vx") } }
        // anchor 20 = +2 ("Project push"); the label must still be the detected working grade (V5).
        val p = KilterRecommender.recommend(history, candidates, anchor = 20.0)
        assertEquals(18.0, p.workingDifficulty)
        assertEquals("V5", p.workingGradeLabel)
    }
}
