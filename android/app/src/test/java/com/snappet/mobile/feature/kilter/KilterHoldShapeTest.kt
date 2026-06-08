package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * JVM unit test for the pure [KilterHoldShape] role→shape mapping. Color-blind support: each role maps
 * to a distinct marker shape (a redundant channel alongside color), so the four roles get four shapes
 * that stay separable in grayscale. Mirrors iOS `testHoldShapeMapsEachRoleToADistinctShape`.
 */
class KilterHoldShapeTest {

    @Test
    fun mapsEachRoleToADistinctShape() {
        assertEquals(KilterHoldShape.TRIANGLE, KilterHoldShape.forRole("start"))
        assertEquals(KilterHoldShape.CIRCLE, KilterHoldShape.forRole("middle"))
        assertEquals(KilterHoldShape.SQUARE, KilterHoldShape.forRole("finish"))
        assertEquals(KilterHoldShape.DIAMOND, KilterHoldShape.forRole("foot"))
        // an unknown role falls back to a circle
        assertEquals(KilterHoldShape.CIRCLE, KilterHoldShape.forRole("hold"))
        // the four roles must be four distinct shapes
        val roleShapes = listOf("start", "middle", "finish", "foot").map { KilterHoldShape.forRole(it) }
        assertEquals(4, roleShapes.toSet().size)
    }
}
