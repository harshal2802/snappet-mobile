package com.snappet.mobile.feature.workout

import com.snappet.mobile.feature.workout.WorkoutAnalytics.SessionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic tests for the issue #95 workout analytics — volume, PRs, per-exercise progress, and the
 * last-time/last-session lookups that drive prefill. No device, and deliberately no `org.json`: the
 * `*View` core functions take the decoded [SessionView], built directly here.
 */
class WorkoutAnalyticsTest {

    private val DAY = 24L * 60 * 60 * 1000

    private fun set(reps: Int?, weight: Double?, unit: WorkoutWeightUnit? = WorkoutWeightUnit.KG, at: Long? = 1L) =
        WorkoutSetLog(actualReps = reps, actualWeight = weight, weightUnit = unit, completedAt = at)

    private fun ex(id: String, vararg sets: WorkoutSetLog) =
        WorkoutSessionExercise(
            exerciseId = id, targetSets = sets.size, targetReps = "10", targetRestSeconds = 0,
            sets = sets.toList(),
        )

    private fun finished(startedAt: Long, vararg ex: WorkoutSessionExercise, name: String = "R", id: String? = "r1") =
        SessionView(startedAt, startedAt + 1000, id, name, ex.toList())

    @Test fun setVolume_multipliesRepsByWeight() {
        assertEquals(480.0, WorkoutAnalytics.setVolumeKg(set(8, 60.0))!!, 0.001)
    }

    @Test fun setVolume_nullWhenIncomplete() {
        assertNull(WorkoutAnalytics.setVolumeKg(set(null, 60.0)))
        assertNull(WorkoutAnalytics.setVolumeKg(set(8, null)))
    }

    @Test fun setVolume_normalisesLbToKg() {
        val v = WorkoutAnalytics.setVolumeKg(set(5, 100.0, WorkoutWeightUnit.LB))!!
        assertEquals(226.8, v, 0.1)
    }

    @Test fun sessionVolume_sumsAllSets() {
        val s = finished(0L, ex("squat", set(8, 60.0), set(8, 60.0)))
        assertEquals(960.0, WorkoutAnalytics.sessionVolumeKgView(s), 0.001)
    }

    @Test fun weeklyVolume_bucketsByWeekNewestLast() {
        val now = 30L * DAY
        val thisWeek = finished(now - 1 * DAY, ex("a", set(10, 50.0)))   // 500
        val twoWeeksAgo = finished(now - 14 * DAY, ex("a", set(10, 20.0))) // 200
        val weeks = WorkoutAnalytics.weeklyVolumeView(listOf(thisWeek, twoWeeksAgo), now, weeks = 8)
        assertEquals(8, weeks.size)
        assertEquals(500.0, weeks.last().volumeKg, 0.001)        // most recent week
        assertEquals(200.0, weeks[8 - 1 - 2].volumeKg, 0.001)    // 2 weeks back
    }

    @Test fun personalRecords_picksHeaviestPerExercise() {
        val s1 = finished(0L, ex("bench", set(5, 80.0), set(5, 100.0)))
        val s2 = finished(DAY, ex("bench", set(8, 90.0)))
        val prs = WorkoutAnalytics.personalRecordsView(listOf(s1, s2))
        assertEquals(1, prs.size)
        assertEquals(100.0, prs[0].weight, 0.001)
        assertEquals(5, prs[0].reps)
    }

    @Test fun personalRecords_comparesAcrossUnits() {
        val lb = finished(0L, ex("dl", set(3, 100.0, WorkoutWeightUnit.LB)))   // ~45 kg
        val kg = finished(DAY, ex("dl", set(3, 50.0, WorkoutWeightUnit.KG)))   // 50 kg wins
        val prs = WorkoutAnalytics.personalRecordsView(listOf(lb, kg))
        assertEquals(50.0, prs[0].weight, 0.001)
        assertEquals(WorkoutWeightUnit.KG, prs[0].unit)
    }

    @Test fun exerciseProgress_orderedOldestToNewest() {
        val older = finished(0L, ex("ohp", set(5, 40.0)))
        val newer = finished(2 * DAY, ex("ohp", set(5, 45.0)))
        val pts = WorkoutAnalytics.exerciseProgressView(listOf(newer, older), "ohp")
        assertEquals(2, pts.size)
        assertEquals(40.0, pts.first().weight, 0.001)
        assertEquals(45.0, pts.last().weight, 0.001)
    }

    @Test fun lastSetFor_returnsLastCompletedSetWithWeight() {
        val s = finished(0L, ex("row", set(10, 30.0), set(8, 35.0)))
        val last = WorkoutAnalytics.lastSetForView(listOf(s), "row")!!
        assertEquals(35.0, last.actualWeight!!, 0.001)
        assertEquals(8, last.actualReps)
    }

    @Test fun lastSetFor_nullWhenNoHistory() {
        assertNull(WorkoutAnalytics.lastSetForView(emptyList(), "nope"))
    }

    @Test fun activeSessions_excludedFromAggregations() {
        val active = SessionView(0L, null, "r", "Live", listOf(ex("a", set(10, 100.0))))
        assertEquals(0.0, WorkoutAnalytics.weeklyVolumeView(listOf(active), DAY).sumOf { it.volumeKg }, 0.001)
        assertTrue(WorkoutAnalytics.personalRecordsView(listOf(active)).isEmpty())
    }
}
