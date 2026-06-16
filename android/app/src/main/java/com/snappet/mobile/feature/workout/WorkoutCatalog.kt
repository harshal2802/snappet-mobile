package com.snappet.mobile.feature.workout

import android.content.Context

/**
 * The exercise catalog. The full set — ~873 exercises — is the public-domain Free Exercise DB
 * bundled at `assets/workout/exercises.json` (the same file the iOS app ships), parsed once at app
 * start via [load]. Until that load completes (or if the asset is somehow unreadable) the API falls
 * back to [curated]: a 20-entry hand-written subset whose ids match the ones [WorkoutStarters]
 * references, so seeded routines always resolve even before the asset is read. Mirrors iOS
 * `ExerciseCatalog`. The on-device-only constraint is honoured — the catalog is a bundled asset, no
 * network.
 */
object WorkoutCatalog {

    /** The loaded full catalog (null until [load] succeeds). */
    @Volatile
    private var loaded: List<WorkoutExercise>? = null

    /** The active catalog: the full bundled DB once loaded, else the curated offline subset. */
    val all: List<WorkoutExercise> get() = loaded ?: curated

    /**
     * Memoized id → exercise index over [all] (review fix). Built lazily on first lookup and
     * rebuilt only when the underlying catalog changes (the curated→loaded swap in [load]); it is
     * NOT rebuilt per call. `WorkoutResolver.name()` calls [byId] once per row in scrollable lists,
     * so re-`associateBy`-ing the 873-entry catalog every lookup was an O(n) cost per row.
     */
    @Volatile
    private var idIndex: Map<String, WorkoutExercise>? = null

    private fun index(): Map<String, WorkoutExercise> =
        idIndex ?: all.associateBy { it.id }.also { idIndex = it }

    fun byId(id: String): WorkoutExercise? = index()[id]

    /** Whether the full bundled catalog has been parsed in (vs. the curated fallback). */
    val isFullyLoaded: Boolean get() = loaded != null

    /**
     * Parse the bundled `exercises.json` asset into the full catalog. Idempotent and cheap to call
     * on every Workout-module open — re-reads only on the first call. Reads + parses off the asset
     * stream; the parse itself is the pure, unit-tested [WorkoutExerciseParser].
     */
    suspend fun load(context: Context) {
        if (loaded != null) return
        val parsed = runCatching {
            context.assets.open("workout/exercises.json").bufferedReader().use { it.readText() }
        }.mapCatching { WorkoutExerciseParser.parse(it) }.getOrDefault(emptyList())
        if (parsed.isNotEmpty()) {
            loaded = parsed.sortedBy { it.name.lowercase() }
            idIndex = null // force a rebuild over the now-full catalog on next lookup
        }
    }

    /** The offline curated subset (ids referenced by [WorkoutStarters]). */
    val curated: List<WorkoutExercise> = listOf(
        ex("Bodyweight_Squat", "Bodyweight Squat", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("quadriceps"), listOf("glutes", "hamstrings"),
            listOf("Stand with feet shoulder-width apart.",
                "Lower your hips back and down until thighs are parallel.",
                "Drive through your heels to return to standing.")),
        ex("Pushups", "Pushups", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("chest"), listOf("triceps", "shoulders"),
            listOf("Start in a plank with hands under shoulders.",
                "Lower your chest toward the floor.",
                "Press back up to the start.")),
        ex("Inverted_Row", "Inverted Row", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BARBELL, listOf("middle back"), listOf("biceps", "lats"),
            listOf("Set a bar at hip height and hang underneath it.",
                "Pull your chest to the bar, squeezing your shoulder blades.",
                "Lower under control.")),
        ex("Plank", "Plank", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("abdominals"), listOf("lower back"),
            listOf("Rest on your forearms and toes.",
                "Keep a straight line from head to heels.",
                "Hold while breathing steadily.")),
        ex("Butt_Lift_Bridge", "Glute Bridge", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("glutes"), listOf("hamstrings"),
            listOf("Lie on your back with knees bent.",
                "Drive your hips toward the ceiling.",
                "Squeeze your glutes at the top, then lower.")),
        ex("Pullups", "Pullups", WorkoutCategory.STRENGTH, WorkoutLevel.INTERMEDIATE,
            WorkoutEquipment.BODY_ONLY, listOf("lats"), listOf("biceps", "middle back"),
            listOf("Hang from a bar with an overhand grip.",
                "Pull your chin above the bar.",
                "Lower with control to a full hang.")),
        ex("Dumbbell_Bicep_Curl", "Dumbbell Bicep Curl", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.DUMBBELL, listOf("biceps"), listOf("forearms"),
            listOf("Stand holding a dumbbell in each hand.",
                "Curl the weights toward your shoulders.",
                "Lower slowly to the start.")),
        ex("Dumbbell_Shoulder_Press", "Dumbbell Shoulder Press", WorkoutCategory.STRENGTH, WorkoutLevel.INTERMEDIATE,
            WorkoutEquipment.DUMBBELL, listOf("shoulders"), listOf("triceps"),
            listOf("Hold dumbbells at shoulder height.",
                "Press overhead until arms are extended.",
                "Lower back to the shoulders.")),
        ex("Bench_Dips", "Bench Dips", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("triceps"), listOf("chest", "shoulders"),
            listOf("Sit on the edge of a bench, hands beside hips.",
                "Slide off and lower your body by bending your elbows.",
                "Press back up.")),
        ex("Side_Lateral_Raise", "Side Lateral Raise", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.DUMBBELL, listOf("shoulders"), emptyList(),
            listOf("Hold a dumbbell in each hand at your sides.",
                "Raise the weights out to shoulder height.",
                "Lower under control.")),
        ex("Goblet_Squat", "Goblet Squat", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.KETTLEBELLS, listOf("quadriceps"), listOf("glutes"),
            listOf("Hold a kettlebell at chest height.",
                "Squat down keeping your chest tall.",
                "Drive back up to standing.")),
        ex("Dumbbell_Lunges", "Dumbbell Lunges", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.DUMBBELL, listOf("quadriceps"), listOf("glutes", "hamstrings"),
            listOf("Hold a dumbbell in each hand.",
                "Step forward and lower your back knee.",
                "Push back to standing and alternate legs.")),
        ex("Romanian_Deadlift", "Romanian Deadlift", WorkoutCategory.STRENGTH, WorkoutLevel.INTERMEDIATE,
            WorkoutEquipment.BARBELL, listOf("hamstrings"), listOf("glutes", "lower back"),
            listOf("Hold a barbell at hip height.",
                "Hinge at the hips, lowering the bar along your legs.",
                "Drive your hips forward to stand.")),
        ex("Standing_Calf_Raises", "Standing Calf Raises", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("calves"), emptyList(),
            listOf("Stand tall on the balls of your feet.",
                "Raise your heels as high as possible.",
                "Lower slowly.")),
        ex("Russian_Twist", "Russian Twist", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("abdominals"), emptyList(),
            listOf("Sit with knees bent, leaning back slightly.",
                "Rotate your torso side to side.",
                "Keep your core engaged throughout.")),
        ex("Dead_Bug", "Dead Bug", WorkoutCategory.STRENGTH, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("abdominals"), emptyList(),
            listOf("Lie on your back, arms and knees up.",
                "Lower an opposite arm and leg toward the floor.",
                "Return and alternate sides.")),
        ex("Cat_Stretch", "Cat Stretch", WorkoutCategory.STRETCHING, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("lower back"), emptyList(),
            listOf("Start on all fours.",
                "Round your spine toward the ceiling.",
                "Then arch it down, moving slowly.")),
        ex("Worlds_Greatest_Stretch", "World's Greatest Stretch", WorkoutCategory.STRETCHING, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("hamstrings"), listOf("glutes"),
            listOf("Step into a deep lunge.",
                "Drop the same-side elbow toward the floor.",
                "Rotate open, reaching toward the ceiling.")),
        ex("Hamstring_Stretch", "Hamstring Stretch", WorkoutCategory.STRETCHING, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("hamstrings"), emptyList(),
            listOf("Sit with one leg extended.",
                "Reach toward your toes, keeping your back flat.",
                "Hold, then switch legs.")),
        ex("Arm_Circles", "Arm Circles", WorkoutCategory.STRETCHING, WorkoutLevel.BEGINNER,
            WorkoutEquipment.BODY_ONLY, listOf("shoulders"), emptyList(),
            listOf("Stand with arms extended to the sides.",
                "Make small circles, gradually growing larger.",
                "Reverse direction.")),
    ).sortedBy { it.name.lowercase() }

    private fun ex(
        id: String, name: String, category: WorkoutCategory, level: WorkoutLevel,
        equipment: WorkoutEquipment?, primary: List<String>, secondary: List<String>,
        instructions: List<String>,
    ) = WorkoutExercise(id, name, category, level, equipment, primary, secondary, instructions)
}

/**
 * Resolves an exercise id to its [WorkoutExercise] (bundled catalog first, then user-created custom
 * exercises) and to a display name. Mirrors iOS `ExerciseResolver`.
 */
class WorkoutResolver(custom: List<WorkoutCustomExercise> = emptyList()) {
    private val customById: Map<String, WorkoutExercise> = custom.associate { it.exerciseId to it.asExercise() }

    fun exercise(id: String): WorkoutExercise? = WorkoutCatalog.byId(id) ?: customById[id]

    /** Display name for an id, preferring an explicit override, then the resolved exercise, then a
     * de-slugged fallback so a since-deleted reference still reads sensibly. */
    fun name(id: String, override: String? = null): String =
        override?.takeIf { it.isNotBlank() }
            ?: exercise(id)?.name
            ?: id.replace('_', ' ')
}
