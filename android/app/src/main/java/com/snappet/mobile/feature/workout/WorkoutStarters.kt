package com.snappet.mobile.feature.workout

/**
 * Starter routines seeded into the store on first open if empty, so users have something to do
 * immediately. A curated subset of the iOS `StarterRoutines` (every exercise id resolves against
 * [WorkoutCatalog]). Seeded at a fixed early `createdAt` so they sort before user routines.
 */
object WorkoutStarters {

    private data class Spec(
        val key: String,
        val name: String,
        val sport: WorkoutSportTag,
        val level: WorkoutLevel?,
        val detail: String?,
        val exercises: List<WorkoutRoutineExercise>,
    )

    private fun re(id: String, sets: Int, reps: String, rest: Int) =
        WorkoutRoutineExercise(exerciseId = id, sets = sets, reps = reps, restSeconds = rest)

    private val specs: List<Spec> = listOf(
        Spec(
            key = "starter-mobility", name = "5-Minute Mobility",
            sport = WorkoutSportTag.GENERAL, level = null,
            detail = "A quick full-body mobility flow to loosen up.",
            exercises = listOf(
                re("Cat_Stretch", 1, "60s", 0),
                re("Worlds_Greatest_Stretch", 1, "30s each side", 0),
                re("Hamstring_Stretch", 1, "30s each leg", 0),
                re("Arm_Circles", 1, "60s", 0),
            ),
        ),
        Spec(
            key = "starter-beginner-full-body", name = "Beginner Full Body",
            sport = WorkoutSportTag.GENERAL, level = WorkoutLevel.BEGINNER,
            detail = "A balanced full-body session for new lifters.",
            exercises = listOf(
                re("Bodyweight_Squat", 3, "12", 60),
                re("Pushups", 3, "10", 60),
                re("Inverted_Row", 3, "10", 60),
                re("Plank", 3, "30s", 45),
                re("Butt_Lift_Bridge", 3, "12", 45),
            ),
        ),
        Spec(
            key = "starter-lower-body", name = "Lower Body",
            sport = WorkoutSportTag.GENERAL, level = WorkoutLevel.INTERMEDIATE,
            detail = "Squat, hinge and single-leg work for the legs.",
            exercises = listOf(
                re("Goblet_Squat", 4, "10", 90),
                re("Dumbbell_Lunges", 3, "10 each leg", 60),
                re("Romanian_Deadlift", 3, "8-10", 90),
                re("Standing_Calf_Raises", 3, "15", 30),
            ),
        ),
    )

    /** Insert any starter not already present (by `starterKey`). Safe to call on every open — it
     * no-ops once everything is seeded. Mirrors iOS `StarterRoutines.seedIfNeeded`. */
    suspend fun seedIfNeeded(dao: WorkoutDao) {
        val present = dao.allRoutines().mapNotNull { it.starterKey }.toSet()
        // Fixed early timestamp so starters sort after the freshest user routine but stay grouped.
        val seedTime = 0L
        for (spec in specs) {
            if (spec.key in present) continue
            dao.insertRoutine(
                WorkoutRoutine.create(
                    name = spec.name,
                    exercises = spec.exercises,
                    isStarter = true,
                    starterKey = spec.key,
                    sport = spec.sport,
                    level = spec.level,
                    detail = spec.detail,
                    createdAt = seedTime,
                ),
            )
        }
    }
}
