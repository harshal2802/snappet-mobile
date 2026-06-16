package com.snappet.mobile.feature.workout

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Pure-JVM tests for [WorkoutCatalog.byId] memoization (review fix). Before the fix the `byId`
 * getter re-`associateBy`-d the whole catalog on *every* lookup; `WorkoutResolver.name()` calls it
 * once per row, so a scrollable list rebuilt the (up to 873-entry) map per row. The fix memoizes the
 * id index, rebuilding it only when the catalog changes.
 *
 * `load()` needs an Android Context (bundled asset), so these run against the curated fallback —
 * which is the index's first population and the path that must stay correct.
 */
class WorkoutCatalogTest {

    @Test fun byId_resolvesKnownCuratedExercise() {
        val ex = WorkoutCatalog.byId("Pushups")
        assertNotNull("a curated id must resolve before load()", ex)
        assertEquals("Pushups", ex!!.id)
        assertEquals("Pushups", ex.name)
    }

    @Test fun byId_unknownIdIsNull() {
        assertNull(WorkoutCatalog.byId("definitely_not_a_real_exercise_id"))
    }

    @Test fun byId_isMemoizedAcrossLookups() {
        // Same map instance backs repeated lookups -> the index is cached, not rebuilt per call.
        val a = WorkoutCatalog.byId("Plank")
        val b = WorkoutCatalog.byId("Plank")
        assertNotNull(a)
        assertSame("repeated lookups must return the same cached instance", a, b)
    }

    @Test fun byId_coversEveryCuratedEntry() {
        // Every curated entry is reachable through the memoized index (no entries dropped on build).
        for (ex in WorkoutCatalog.curated) {
            assertSame("curated id ${ex.id} must resolve to its own instance", ex, WorkoutCatalog.byId(ex.id))
        }
    }
}
