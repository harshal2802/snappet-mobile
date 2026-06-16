package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #93: the manual editor's live grade estimate runs the same pure linear grade model the
 * Generate tab uses, over the authored `placementId → role` holds. No ONNX, no device — exactly the
 * `meta.json` the generator already ships. Mirrors the iOS `estimateManualGrade` tests.
 */
class KilterManualGradeTest {

    // Reuses the generator test's tiny meta: HOLD_100_12 (start, w_hold 1.0), HOLD_102_14 (finish),
    // HOLD_104_12 (start, w_hold 0.7). angle 40 → w_angle 0.5; bias 2.0; y_mean 10.0; w_nomatch 1.0.
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

    @Test fun holdTokensMapAuthoredAssignmentsToVocab() {
        val m = model()
        // placement 100 @ start (roleId 12) → token index 8; placement 102 @ finish (14) → index 10.
        val tokens = KilterClimbGenerator.holdTokens(
            mapOf(100 to KilterAuthorRole.START, 102 to KilterAuthorRole.FINISH), m,
        )
        assertEquals(setOf(8, 10), tokens.toSet())
    }

    @Test fun holdTokensDropOutOfVocabPlacements() {
        val m = model()
        // placement 999 isn't in the vocab for this board → dropped; only the valid one survives.
        val tokens = KilterClimbGenerator.holdTokens(
            mapOf(100 to KilterAuthorRole.START, 999 to KilterAuthorRole.MIDDLE), m,
        )
        assertEquals(listOf(8), tokens)
    }

    @Test fun estimateMatchesLinearModel() {
        val m = model()
        // tokens 8 (w 1.0) + 10 (w 0) ; angle 40 (0.5); bias 2.0; y_mean 10.0; matching (no nomatch).
        // = 2.0 + 0.5 + 1.0 + 10.0 = 13.5
        val est = KilterClimbGenerator.estimateManualGrade(
            mapOf(100 to KilterAuthorRole.START, 102 to KilterAuthorRole.FINISH), 40, false, m,
        )
        assertNotNull(est)
        assertEquals(13.5, est!!, 1e-9)
    }

    @Test fun nomatchAddsItsWeight() {
        val m = model()
        val matching = KilterClimbGenerator.estimateManualGrade(
            mapOf(100 to KilterAuthorRole.START), 40, false, m,
        )!!
        val nomatch = KilterClimbGenerator.estimateManualGrade(
            mapOf(100 to KilterAuthorRole.START), 40, true, m,
        )!!
        assertEquals(matching + 1.0, nomatch, 1e-9)
    }

    @Test fun emptyOrUnknownAssignmentsGiveNull() {
        val m = model()
        assertNull(KilterClimbGenerator.estimateManualGrade(emptyMap(), 40, false, m))
        // All placements out of vocab → no tokens → null (estimate hidden gracefully).
        assertNull(KilterClimbGenerator.estimateManualGrade(mapOf(999 to KilterAuthorRole.START), 40, false, m))
    }

    @Test fun estimateChangesAsHoldsAreAdded() {
        val m = model()
        val one = KilterClimbGenerator.estimateManualGrade(mapOf(104 to KilterAuthorRole.START), 40, false, m)!!
        val two = KilterClimbGenerator.estimateManualGrade(
            mapOf(104 to KilterAuthorRole.START, 100 to KilterAuthorRole.START), 40, false, m,
        )!!
        // Adding HOLD_100 (w 1.0) on top of HOLD_104 (w 0.7) raises the estimate.
        assertTrue(two > one)
    }
}
