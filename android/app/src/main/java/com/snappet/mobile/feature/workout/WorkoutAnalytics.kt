package com.snappet.mobile.feature.workout

import java.util.Calendar

/**
 * Pure aggregations over finished workout sessions (issue #95). The public API takes
 * [WorkoutSession]s (extracting their per-set logs once via `.exercises`), but the math runs on the
 * decoded [SessionView] value type so the core logic is unit-tested with no device and no `org.json`
 * (Android's `org.json` is stubbed-to-throw in JVM tests, so tests build [SessionView] directly).
 * The Android counterpart to iOS `WorkoutDashboardSection` / `ExerciseProgressView`. Weight is
 * normalised to kg for comparison so kg/lb-mixed history still aggregates sanely; display layers
 * format in the user's preferred unit.
 */
object WorkoutAnalytics {

    private const val DAY_MILLIS = 24L * 60 * 60 * 1000
    private const val WEEK_MILLIS = 7 * DAY_MILLIS
    /** 1 lb in kg — used to normalise mixed-unit history into one comparison number. */
    private const val LB_TO_KG = 0.45359237

    /** A decoded, JSON-free view of a session (the unit it of work the math runs on). */
    data class SessionView(
        val startedAt: Long,
        val finishedAt: Long?,
        val routineId: String?,
        val routineName: String,
        val exercises: List<WorkoutSessionExercise>,
    ) {
        val isActive: Boolean get() = finishedAt == null
    }

    private fun WorkoutSession.toView() =
        SessionView(startedAt, finishedAt, routineId, routineName, exercises)

    // --- public API over WorkoutSession (thin wrappers) ---------------------

    fun sessionVolumeKg(session: WorkoutSession): Double = sessionVolumeKgView(session.toView())

    fun weeklyVolume(history: List<WorkoutSession>, now: Long, weeks: Int = 8): List<WeeklyVolume> =
        weeklyVolumeView(history.map { it.toView() }, now, weeks)

    fun personalRecords(history: List<WorkoutSession>): List<PersonalRecord> =
        personalRecordsView(history.map { it.toView() })

    fun exerciseProgress(history: List<WorkoutSession>, exerciseId: String): List<ProgressPoint> =
        exerciseProgressView(history.map { it.toView() }, exerciseId)

    fun lastSession(history: List<WorkoutSession>, routineId: String?, routineName: String): WorkoutSession? =
        history.filter { !it.isActive && (it.routineId == routineId || it.routineName == routineName) }
            .maxByOrNull { it.startedAt }

    fun lastSetFor(history: List<WorkoutSession>, exerciseId: String): WorkoutSetLog? =
        lastSetForView(history.map { it.toView() }, exerciseId)

    // --- core math over SessionView (org.json-free; directly unit-tested) ----

    /** A logged set's actual reps × weight (in kg), or null when either is missing. */
    fun setVolumeKg(set: WorkoutSetLog): Double? {
        val reps = set.actualReps ?: return null
        val weight = set.actualWeight ?: return null
        val kg = if (set.weightUnit == WorkoutWeightUnit.LB) weight * LB_TO_KG else weight
        return reps * kg
    }

    fun sessionVolumeKgView(session: SessionView): Double =
        session.exercises.sumOf { ex -> ex.sets.mapNotNull { setVolumeKg(it) }.sum() }

    /** One bar of the volume chart: the week's start (midnight) and its total tonnage. */
    data class WeeklyVolume(val weekStart: Long, val volumeKg: Double)

    fun weeklyVolumeView(history: List<SessionView>, now: Long, weeks: Int = 8): List<WeeklyVolume> {
        val todayStart = startOfDay(now)
        val buckets = DoubleArray(weeks)
        for (s in history) {
            if (s.isActive) continue
            val daysAgo = ((todayStart - startOfDay(s.startedAt)) / DAY_MILLIS).toInt()
            if (daysAgo < 0) continue
            val weekIdx = daysAgo / 7
            if (weekIdx in 0 until weeks) buckets[weeks - 1 - weekIdx] += sessionVolumeKgView(s)
        }
        return (0 until weeks).map { i ->
            val weekStart = todayStart - (weeks - 1 - i).toLong() * WEEK_MILLIS
            WeeklyVolume(weekStart, buckets[i])
        }
    }

    /** A per-exercise personal record: the heaviest completed set, with its reps. */
    data class PersonalRecord(
        val exerciseId: String,
        val displayName: String?,
        val weight: Double,
        val unit: WorkoutWeightUnit,
        val reps: Int,
        val achievedAt: Long,
    )

    fun personalRecordsView(history: List<SessionView>): List<PersonalRecord> {
        val best = HashMap<String, Pair<Double, PersonalRecord>>() // id -> (kg, record)
        for (s in history) {
            if (s.isActive) continue
            for (ex in s.exercises) {
                for (set in ex.sets) {
                    val w = set.actualWeight ?: continue
                    val reps = set.actualReps ?: continue
                    if (w <= 0) continue
                    val kg = if (set.weightUnit == WorkoutWeightUnit.LB) w * LB_TO_KG else w
                    val candidate = PersonalRecord(
                        exerciseId = ex.exerciseId, displayName = ex.displayName,
                        weight = w, unit = set.weightUnit ?: WorkoutWeightUnit.KG,
                        reps = reps, achievedAt = set.completedAt ?: s.startedAt,
                    )
                    val current = best[ex.exerciseId]
                    if (current == null || kg > current.first) best[ex.exerciseId] = kg to candidate
                }
            }
        }
        return best.values.map { it.second }.sortedByDescending {
            if (it.unit == WorkoutWeightUnit.LB) it.weight * LB_TO_KG else it.weight
        }
    }

    /** One point on an exercise's progress line: a session date and that session's best set. */
    data class ProgressPoint(val date: Long, val weight: Double, val unit: WorkoutWeightUnit, val reps: Int)

    fun exerciseProgressView(history: List<SessionView>, exerciseId: String): List<ProgressPoint> {
        val points = ArrayList<ProgressPoint>()
        for (s in history.sortedBy { it.startedAt }) {
            if (s.isActive) continue
            val ex = s.exercises.firstOrNull { it.exerciseId == exerciseId } ?: continue
            val bestSet = ex.sets
                .filter { it.actualWeight != null && it.isCompleted }
                .maxByOrNull {
                    val w = it.actualWeight ?: 0.0
                    if (it.weightUnit == WorkoutWeightUnit.LB) w * LB_TO_KG else w
                } ?: continue
            points.add(
                ProgressPoint(
                    date = bestSet.completedAt ?: s.startedAt,
                    weight = bestSet.actualWeight ?: 0.0,
                    unit = bestSet.weightUnit ?: WorkoutWeightUnit.KG,
                    reps = bestSet.actualReps ?: 0,
                ),
            )
        }
        return points
    }

    fun lastSetForView(history: List<SessionView>, exerciseId: String): WorkoutSetLog? {
        for (s in history.sortedByDescending { it.startedAt }) {
            if (s.isActive) continue
            val ex = s.exercises.firstOrNull { it.exerciseId == exerciseId } ?: continue
            val last = ex.sets.lastOrNull { it.isCompleted && it.actualWeight != null }
                ?: ex.sets.lastOrNull { it.isCompleted }
            if (last != null) return last
        }
        return null
    }

    private fun startOfDay(millis: Long): Long {
        val cal = Calendar.getInstance()
        cal.timeInMillis = millis
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }
}
