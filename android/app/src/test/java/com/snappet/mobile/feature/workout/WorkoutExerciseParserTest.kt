package com.snappet.mobile.feature.workout

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic tests for the bundled-catalog parser + search (issue #87). The Free Exercise DB schema
 * is exercised with small fixtures; no Android context needed.
 */
class WorkoutExerciseParserTest {

    private val sample = """
        [
          { "id": "Barbell_Squat", "name": "Barbell Squat", "level": "intermediate",
            "equipment": "barbell", "primaryMuscles": ["quadriceps"], "secondaryMuscles": ["glutes"],
            "instructions": ["Step 1.", "Step 2."], "category": "strength" },
          { "id": "Jumping_Jacks", "name": "Jumping Jacks", "level": "beginner",
            "equipment": "body only", "primaryMuscles": ["cardiovascular system"], "secondaryMuscles": [],
            "instructions": ["Jump."], "category": "cardio" }
        ]
    """.trimIndent()

    @Test fun parse_readsAllEntriesAndFields() {
        val all = WorkoutExerciseParser.parse(sample)
        assertEquals(2, all.size)
        val squat = all.first { it.id == "Barbell_Squat" }
        assertEquals("Barbell Squat", squat.name)
        assertEquals(WorkoutCategory.STRENGTH, squat.category)
        assertEquals(WorkoutLevel.INTERMEDIATE, squat.level)
        assertEquals(WorkoutEquipment.BARBELL, squat.equipment)
        assertEquals(listOf("quadriceps"), squat.primaryMuscles)
        assertEquals(2, squat.instructions.size)
    }

    @Test fun parse_skipsEntriesMissingIdOrName() {
        val bad = """[ { "name": "No id" }, { "id": "no-name" }, { "id": "ok", "name": "OK" } ]"""
        val all = WorkoutExerciseParser.parse(bad)
        assertEquals(1, all.size)
        assertEquals("ok", all[0].id)
    }

    @Test fun parse_malformedJson_returnsEmpty() {
        assertTrue(WorkoutExerciseParser.parse("not json").isEmpty())
        assertTrue(WorkoutExerciseParser.parse("").isEmpty())
    }

    @Test fun parse_unknownCategoryDefaultsToStrength() {
        val j = """[ { "id": "x", "name": "X", "category": "made-up" } ]"""
        assertEquals(WorkoutCategory.STRENGTH, WorkoutExerciseParser.parse(j)[0].category)
    }

    @Test fun search_matchesNameCaseInsensitively() {
        val all = WorkoutExerciseParser.parse(sample)
        assertEquals(1, WorkoutExerciseParser.search(all, "squat").size)
        assertEquals(1, WorkoutExerciseParser.search(all, "SQUAT").size)
    }

    @Test fun search_matchesMuscleAndEquipmentAndCategory() {
        val all = WorkoutExerciseParser.parse(sample)
        assertEquals("Barbell Squat", WorkoutExerciseParser.search(all, "quadriceps").single().name)
        assertEquals("Jumping Jacks", WorkoutExerciseParser.search(all, "cardio").single().name)
        assertEquals("Barbell Squat", WorkoutExerciseParser.search(all, "barbell").single().name)
    }

    @Test fun search_emptyQueryReturnsAll() {
        val all = WorkoutExerciseParser.parse(sample)
        assertEquals(all.size, WorkoutExerciseParser.search(all, "   ").size)
    }

    @Test fun search_noMatchReturnsEmpty() {
        val all = WorkoutExerciseParser.parse(sample)
        assertTrue(WorkoutExerciseParser.search(all, "zzzzz").isEmpty())
    }

    @Test fun setSummary_formatsRepsAndWeight() {
        assertEquals("8 reps × 60 kg", setSummary(WorkoutSetLog(8, 60.0, WorkoutWeightUnit.KG, 1L), WorkoutWeightUnit.LB))
        assertEquals("12 reps", setSummary(WorkoutSetLog(12, null, null, 1L), WorkoutWeightUnit.KG))
    }
}
