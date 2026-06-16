package com.snappet.mobile.feature.workout

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Pure parser for the bundled Free Exercise DB (`assets/workout/exercises.json`, ~873 entries) —
 * the Android counterpart to the iOS `ExerciseCatalog`'s JSON decode. Kept platform-free (takes a
 * raw JSON `String`, returns value types) so it runs in the JVM unit suite with no Android context.
 *
 * Uses `kotlinx.serialization` (already a project dependency, JVM-available) rather than `org.json`
 * specifically so the parse + search are exercised in `:app:testDebugUnitTest` — Android's `org.json`
 * is stubbed-to-throw in JVM unit tests. The schema mirrors the public-domain Free Exercise DB the
 * iOS app already ships: `{ id, name, level, equipment, primaryMuscles, secondaryMuscles,
 * instructions, category }`.
 */
internal object WorkoutExerciseParser {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** Parse the whole catalog JSON array. Malformed entries are skipped, never crashing the app. */
    fun parse(jsonText: String): List<WorkoutExercise> = runCatching {
        val element = json.parseToJsonElement(jsonText)
        val arr = element as? JsonArray ?: return emptyList()
        arr.mapNotNull { (it as? JsonObject)?.let { obj -> parseEntry(obj) } }
    }.getOrDefault(emptyList())

    /** Parse one exercise object. Returns null if it has no usable id/name. */
    fun parseEntry(o: JsonObject): WorkoutExercise? {
        val id = o.str("id") ?: return null
        val name = o.str("name") ?: return null
        return WorkoutExercise(
            id = id,
            name = name,
            category = WorkoutCategory.from(o.str("category")),
            level = WorkoutLevel.from(o.str("level")),
            equipment = o.str("equipment")?.let { WorkoutEquipment.from(it) },
            primaryMuscles = o.strList("primaryMuscles"),
            secondaryMuscles = o.strList("secondaryMuscles"),
            instructions = o.strList("instructions"),
        )
    }

    private fun JsonObject.str(key: String): String? =
        runCatching { this[key]?.jsonPrimitive?.contentOrNullSafe() }.getOrNull()?.takeIf { it.isNotBlank() }

    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
        if (this is kotlinx.serialization.json.JsonNull) null else content

    private fun JsonObject.strList(key: String): List<String> = runCatching {
        (this[key] as? JsonArray ?: this[key]?.jsonArray)
            ?.mapNotNull { it.jsonPrimitive.contentOrNullSafe()?.takeIf { s -> s.isNotBlank() } }
            ?: emptyList()
    }.getOrDefault(emptyList())

    /**
     * Case-insensitive substring search over name + muscles + equipment + category, the same fields
     * the iOS `.searchable` browser filters on. Pure so the picker / browse search is unit-tested.
     */
    fun search(all: List<WorkoutExercise>, query: String): List<WorkoutExercise> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return all
        return all.filter { ex ->
            ex.name.lowercase().contains(q) ||
                ex.primaryMuscles.any { it.lowercase().contains(q) } ||
                ex.secondaryMuscles.any { it.lowercase().contains(q) } ||
                ex.equipment?.display?.lowercase()?.contains(q) == true ||
                ex.category.display.lowercase().contains(q)
        }
    }
}
