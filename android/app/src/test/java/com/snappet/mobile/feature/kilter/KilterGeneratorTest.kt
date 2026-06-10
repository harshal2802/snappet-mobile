package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit coverage for the on-device generator's pure core — meta decoding + the autoregressive sampler +
 * the grade model — with a deterministic stub session (no ONNX Runtime, no model file, no device). Mirrors
 * iOS `KilterGeneratorTests`.
 */
class KilterGeneratorTest {

    private val metaJson = """
    {
      "block": 8, "pad": 0,
      "specials": {"BOS": 1, "EOS": 2, "PAD": 0, "MATCH": 3, "NOMATCH": 4},
      "firstHoldId": 8,
      "itos": ["PAD","BOS","EOS","MATCH","NOMATCH","SIZE_10","ANGLE_40","GRADE_17",
               "HOLD_100_12","HOLD_101_13","HOLD_102_14","HOLD_103_15","HOLD_104_12","HOLD_105_14"],
      "sizes": [{"id": 10, "name": "12 x 12", "box": [0,144,0,156]}],
      "roles": [{"id":12,"name":"start","color":"00DD00"},{"id":13,"name":"middle","color":"00FFFF"},
                {"id":14,"name":"finish","color":"FF00FF"},{"id":15,"name":"foot","color":"FFA500"}],
      "sizeMasks": {"10": [2,8,9,10,11,12,13]},
      "gradeModel": {
        "w_hold": [0,0,0,0,0,0,0,0,1.0,0,0,0,0.7,0],
        "w_angle": [0.5], "w_nomatch": 1.0, "bias": 2.0,
        "angle_index": {"40": 0}, "y_mean": 10.0, "first_hold_id": 8
      },
      "grades": [17], "gradeLabels": {"17": "6a/V3"}, "angles": [40], "defaultSize": 10
    }
    """.trimIndent()

    private fun model() = KilterGeneratorModel.parse(metaJson)

    private fun request(maxHolds: Int = 20) =
        KilterGenerateRequest(sizeId = 10, angle = 40, grade = 17, nomatch = false, maxHolds = maxHolds, minHolds = 4)

    /** Uniform (zero) logits → the RNG decides the pick, making generation deterministic. */
    private class UniformSession(val vocab: Int) : KilterLogitsProviding {
        override fun logits(tokens: List<Int>) = FloatArray(vocab)
    }

    @Test fun metaDecodesAndBuildsMaps() {
        val m = model()
        assertEquals(8, m.meta.block)
        assertEquals(5, m.stoi["SIZE_10"])
        assertEquals(100, m.placementOf[8])
        assertEquals(12, m.roleOf[8])
        assertEquals("finish", m.roleName[14])
        assertNull(m.placementOf[5])
    }

    @Test fun deterministicGeneration() {
        val m = model()
        val gen = KilterClimbGenerator(m, UniformSession(m.meta.itos.size))
        val climb = gen.generate(request()) { 0.0 }
        assertEquals("p100r12p101r13p102r14p103r15", climb.frames)
        assertEquals(listOf(8, 9, 10, 11), climb.holdTokens)
    }

    @Test fun alwaysHasStartAndFinish() {
        val m = model()
        val gen = KilterClimbGenerator(m, UniformSession(m.meta.itos.size))
        val climb = gen.generate(request()) { 0.5 }
        val roles = climb.holdTokens.mapNotNull { m.roleOf[it]?.let { r -> m.roleName[r] } }.toSet()
        assertTrue(roles.contains("start"))
        assertTrue(roles.contains("finish"))
    }

    @Test fun repairAddsMissingFinish() {
        val m = model()
        val gen = KilterClimbGenerator(m, UniformSession(m.meta.itos.size))
        val climb = gen.generate(request(maxHolds = 2)) { 0.0 }
        val roles = climb.holdTokens.mapNotNull { m.roleOf[it]?.let { r -> m.roleName[r] } }
        assertTrue(roles.contains("start"))
        assertTrue(roles.contains("finish"))
    }

    @Test fun noDuplicatePlacements() {
        val m = model()
        val gen = KilterClimbGenerator(m, UniformSession(m.meta.itos.size))
        val climb = gen.generate(request()) { 0.3 }
        val placements = climb.holdTokens.mapNotNull { m.placementOf[it] }
        assertEquals(placements.size, placements.toSet().size)
    }

    @Test fun allHoldsAreInSizeMask() {
        val m = model()
        val mask = m.meta.sizeMasks["10"]!!.toSet()
        val gen = KilterClimbGenerator(m, UniformSession(m.meta.itos.size))
        val climb = gen.generate(request()) { 0.7 }
        for (t in climb.holdTokens) assertTrue(mask.contains(t))
    }

    @Test fun predictGradeMatchesLinearModel() {
        val m = model()
        assertEquals(13.5, KilterClimbGenerator.predictGrade(m, listOf(8), 40, false), 1e-9)
        assertEquals(14.5, KilterClimbGenerator.predictGrade(m, listOf(8), 40, true), 1e-9)
    }

    @Test fun sampleHonorsRngBoundaries() {
        assertEquals(7, KilterClimbGenerator.sample(listOf(0f, 0f, 0f), listOf(7, 8, 9)) { 0.0 })
        assertEquals(9, KilterClimbGenerator.sample(listOf(0f, 0f, 0f), listOf(7, 8, 9)) { 0.999 })
    }
}
