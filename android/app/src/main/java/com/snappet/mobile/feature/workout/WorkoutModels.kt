package com.snappet.mobile.feature.workout

import androidx.room.Entity
import androidx.room.PrimaryKey
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persistence + value types for the Workout Tracker mini-app (module id `workout-log`).
 *
 * Mirrors the iOS `WorkoutModels.swift` SwiftData models. Complex nested data (a routine's
 * exercise prescriptions, a session's per-set logs) is stored as a JSON `String` column rather
 * than via a Room relationship or a shared TypeConverter — it's always loaded/edited whole.
 * Decoding helpers live on the companion objects.
 *
 * NOTE: these types are also imported by the flagship "Workout Reels" integrator, so every
 * public type is prefixed `Workout*` to stay unambiguous.
 */

// MARK: - Enums (raw values match the iOS catalog so display/lookup stays identical)

enum class WorkoutCategory(val raw: String, val display: String) {
    STRENGTH("strength", "Strength"),
    CARDIO("cardio", "Cardio"),
    STRETCHING("stretching", "Stretching"),
    PLYOMETRICS("plyometrics", "Plyometrics"),
    POWERLIFTING("powerlifting", "Powerlifting"),
    OLYMPIC("olympic weightlifting", "Olympic"),
    STRONGMAN("strongman", "Strongman");

    companion object {
        fun from(raw: String?): WorkoutCategory =
            entries.firstOrNull { it.raw == raw } ?: STRENGTH
    }
}

enum class WorkoutLevel(val raw: String, val display: String) {
    BEGINNER("beginner", "Beginner"),
    INTERMEDIATE("intermediate", "Intermediate"),
    EXPERT("expert", "Expert");

    companion object {
        fun from(raw: String?): WorkoutLevel =
            entries.firstOrNull { it.raw == raw } ?: BEGINNER
    }
}

enum class WorkoutEquipment(val raw: String, val display: String) {
    BODY_ONLY("body only", "Body Only"),
    DUMBBELL("dumbbell", "Dumbbell"),
    BARBELL("barbell", "Barbell"),
    KETTLEBELLS("kettlebells", "Kettlebells"),
    MACHINE("machine", "Machine"),
    CABLE("cable", "Cable"),
    BANDS("bands", "Bands"),
    FOAM_ROLL("foam roll", "Foam Roll"),
    OTHER("other", "Other");

    companion object {
        fun from(raw: String?): WorkoutEquipment? =
            entries.firstOrNull { it.raw == raw }
    }
}

enum class WorkoutWeightUnit(val raw: String, val display: String) {
    KG("kg", "kg"),
    LB("lb", "lb");

    companion object {
        fun from(raw: String?): WorkoutWeightUnit =
            entries.firstOrNull { it.raw == raw } ?: KG
    }
}

enum class WorkoutSportTag(val raw: String, val display: String) {
    GENERAL("general", "General"),
    CLIMBING("climbing", "Climbing"),
    CALISTHENICS("calisthenics", "Calisthenics");

    companion object {
        fun from(raw: String?): WorkoutSportTag? =
            entries.firstOrNull { it.raw == raw }
    }
}

// MARK: - Catalog exercise (value type, not persisted — see [WorkoutCatalog])

/** A single bundled exercise. Mirrors the iOS `Exercise` value type (subset of fields). */
data class WorkoutExercise(
    val id: String,
    val name: String,
    val category: WorkoutCategory,
    val level: WorkoutLevel,
    val equipment: WorkoutEquipment?,
    val primaryMuscles: List<String>,
    val secondaryMuscles: List<String>,
    val instructions: List<String>,
) {
    /** Short list subtitle, e.g. "Dumbbell · Chest · Beginner". */
    val subtitle: String
        get() {
            val parts = mutableListOf<String>()
            equipment?.let { parts.add(it.display) }
            primaryMuscles.firstOrNull()?.let { parts.add(it.replaceFirstChar(Char::uppercase)) }
            parts.add(level.display)
            return parts.joinToString(" · ")
        }
}

// MARK: - Nested value types (persisted as JSON inside the entities below)

/**
 * One exercise slot inside a routine: a target prescription (sets × reps, rest, optional weight).
 * `reps` is free text ("12", "8-12", "30s") like the iOS app. Mirrors iOS `RoutineExercise`.
 */
data class WorkoutRoutineExercise(
    val exerciseId: String,
    val sets: Int,
    val reps: String,
    val restSeconds: Int,
    val weight: Double? = null,
    val displayName: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("exerciseId", exerciseId)
        put("sets", sets)
        put("reps", reps)
        put("restSeconds", restSeconds)
        weight?.let { put("weight", it) }
        displayName?.let { put("displayName", it) }
    }

    companion object {
        fun fromJson(o: JSONObject) = WorkoutRoutineExercise(
            exerciseId = o.optString("exerciseId"),
            sets = o.optInt("sets", 1),
            reps = o.optString("reps", ""),
            restSeconds = o.optInt("restSeconds", 0),
            weight = if (o.has("weight")) o.optDouble("weight") else null,
            displayName = if (o.has("displayName")) o.optString("displayName") else null,
        )
    }
}

/** One logged set during a session. Mirrors iOS `SetLog`. */
data class WorkoutSetLog(
    val actualReps: Int? = null,
    val actualWeight: Double? = null,
    val weightUnit: WorkoutWeightUnit? = null,
    val completedAt: Long? = null,
) {
    val isCompleted: Boolean get() = completedAt != null

    fun toJson(): JSONObject = JSONObject().apply {
        actualReps?.let { put("actualReps", it) }
        actualWeight?.let { put("actualWeight", it) }
        weightUnit?.let { put("weightUnit", it.raw) }
        completedAt?.let { put("completedAt", it) }
    }

    companion object {
        fun fromJson(o: JSONObject) = WorkoutSetLog(
            actualReps = if (o.has("actualReps")) o.optInt("actualReps") else null,
            actualWeight = if (o.has("actualWeight")) o.optDouble("actualWeight") else null,
            weightUnit = if (o.has("weightUnit")) WorkoutWeightUnit.from(o.optString("weightUnit")) else null,
            completedAt = if (o.has("completedAt")) o.optLong("completedAt") else null,
        )
    }
}

/**
 * An exercise as it appears in a session: a snapshot of the routine target plus the per-set log
 * the user fills in while training. Mirrors iOS `SessionExercise`.
 */
data class WorkoutSessionExercise(
    val exerciseId: String,
    val targetSets: Int,
    val targetReps: String,
    val targetRestSeconds: Int,
    val targetWeight: Double? = null,
    val sets: List<WorkoutSetLog>,
    val skipped: Boolean = false,
    val displayName: String? = null,
) {
    val completedSetCount: Int get() = sets.count { it.isCompleted }

    fun toJson(): JSONObject = JSONObject().apply {
        put("exerciseId", exerciseId)
        put("targetSets", targetSets)
        put("targetReps", targetReps)
        put("targetRestSeconds", targetRestSeconds)
        targetWeight?.let { put("targetWeight", it) }
        put("skipped", skipped)
        displayName?.let { put("displayName", it) }
        put("sets", JSONArray().apply { sets.forEach { put(it.toJson()) } })
    }

    companion object {
        fun fromJson(o: JSONObject): WorkoutSessionExercise {
            val setsArr = o.optJSONArray("sets") ?: JSONArray()
            val sets = (0 until setsArr.length()).map { WorkoutSetLog.fromJson(setsArr.getJSONObject(it)) }
            return WorkoutSessionExercise(
                exerciseId = o.optString("exerciseId"),
                targetSets = o.optInt("targetSets", 1),
                targetReps = o.optString("targetReps", ""),
                targetRestSeconds = o.optInt("targetRestSeconds", 0),
                targetWeight = if (o.has("targetWeight")) o.optDouble("targetWeight") else null,
                sets = sets,
                skipped = o.optBoolean("skipped", false),
                displayName = if (o.has("displayName")) o.optString("displayName") else null,
            )
        }
    }
}

// MARK: - Room entities

/**
 * A workout routine: an ordered list of exercise prescriptions, stored as a JSON column. Starter
 * routines carry `isStarter == true` + a stable `starterKey`. Mirrors iOS `Routine`.
 */
@Entity(tableName = "workout_routines")
data class WorkoutRoutine(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Stable UUID identity (used to key sessions/lookups independent of the Room row id). */
    val routineId: String = java.util.UUID.randomUUID().toString(),
    val name: String,
    /** JSON array of [WorkoutRoutineExercise]. */
    val exercisesJson: String = "[]",
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val isStarter: Boolean = false,
    val starterKey: String? = null,
    val sportRaw: String? = null,
    val levelRaw: String? = null,
    val detail: String? = null,
) {
    val exercises: List<WorkoutRoutineExercise> get() = WorkoutJson.decodeRoutineExercises(exercisesJson)
    val totalSets: Int get() = exercises.sumOf { it.sets }
    val sport: WorkoutSportTag? get() = WorkoutSportTag.from(sportRaw)
    val level: WorkoutLevel? get() = levelRaw?.let { WorkoutLevel.from(it) }

    companion object {
        fun create(
            name: String,
            exercises: List<WorkoutRoutineExercise>,
            isStarter: Boolean = false,
            starterKey: String? = null,
            sport: WorkoutSportTag? = null,
            level: WorkoutLevel? = null,
            detail: String? = null,
            createdAt: Long = System.currentTimeMillis(),
        ) = WorkoutRoutine(
            name = name,
            exercisesJson = WorkoutJson.encodeRoutineExercises(exercises),
            isStarter = isStarter,
            starterKey = starterKey,
            sportRaw = sport?.raw,
            levelRaw = level?.raw,
            detail = detail,
            createdAt = createdAt,
            updatedAt = createdAt,
        )
    }
}

/**
 * A workout session. While live, `finishedAt == null`. When finished/saved it's stamped and joins
 * history. Per-exercise set logs are stored as a JSON column. Mirrors iOS `WorkoutSession`.
 */
@Entity(tableName = "workout_sessions")
data class WorkoutSession(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val routineId: String? = null,
    val routineName: String,
    val startedAt: Long = System.currentTimeMillis(),
    val finishedAt: Long? = null,
    /** JSON array of [WorkoutSessionExercise]. */
    val exercisesJson: String = "[]",
) {
    val exercises: List<WorkoutSessionExercise> get() = WorkoutJson.decodeSessionExercises(exercisesJson)
    val isActive: Boolean get() = finishedAt == null
    val durationMillis: Long get() = (finishedAt ?: System.currentTimeMillis()) - startedAt
    val completedSetCount: Int get() = exercises.sumOf { it.completedSetCount }
    val completedExerciseCount: Int get() = exercises.count { !it.skipped && it.completedSetCount > 0 }

    fun withExercises(exercises: List<WorkoutSessionExercise>): WorkoutSession =
        copy(exercisesJson = WorkoutJson.encodeSessionExercises(exercises))

    companion object {
        fun create(
            routineId: String?,
            routineName: String,
            exercises: List<WorkoutSessionExercise>,
        ) = WorkoutSession(
            routineId = routineId,
            routineName = routineName,
            exercisesJson = WorkoutJson.encodeSessionExercises(exercises),
        )
    }
}

/**
 * A user-created exercise, stored separately from the bundled catalog and merged into the browse
 * list at runtime. Mirrors iOS `CustomExercise`.
 */
@Entity(tableName = "workout_custom_exercises")
data class WorkoutCustomExercise(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** Stable id, prefixed "custom-" so it never collides with bundled ids. */
    val exerciseId: String = "custom-${java.util.UUID.randomUUID()}",
    val name: String,
    val categoryRaw: String = WorkoutCategory.STRENGTH.raw,
    val levelRaw: String = WorkoutLevel.BEGINNER.raw,
    val equipmentRaw: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
) {
    fun asExercise(): WorkoutExercise = WorkoutExercise(
        id = exerciseId,
        name = name,
        category = WorkoutCategory.from(categoryRaw),
        level = WorkoutLevel.from(levelRaw),
        equipment = WorkoutEquipment.from(equipmentRaw),
        primaryMuscles = emptyList(),
        secondaryMuscles = emptyList(),
        instructions = emptyList(),
    )
}

// MARK: - JSON (de)serialization for the composite columns (org.json, no extra deps)

internal object WorkoutJson {
    fun encodeRoutineExercises(list: List<WorkoutRoutineExercise>): String =
        JSONArray().apply { list.forEach { put(it.toJson()) } }.toString()

    fun decodeRoutineExercises(json: String): List<WorkoutRoutineExercise> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length()).map { WorkoutRoutineExercise.fromJson(arr.getJSONObject(it)) }
    }.getOrDefault(emptyList())

    fun encodeSessionExercises(list: List<WorkoutSessionExercise>): String =
        JSONArray().apply { list.forEach { put(it.toJson()) } }.toString()

    fun decodeSessionExercises(json: String): List<WorkoutSessionExercise> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length()).map { WorkoutSessionExercise.fromJson(arr.getJSONObject(it)) }
    }.getOrDefault(emptyList())
}
