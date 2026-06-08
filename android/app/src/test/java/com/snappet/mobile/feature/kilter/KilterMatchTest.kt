package com.snappet.mobile.feature.kilter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit test for the pure [kilterDescriptionForbidsMatching] detector — the fallback that reads the
 * Kilter "No matching" setter note from a climb's description when the catalog lacks the dedicated
 * `is_nomatch` column. Default (no note) = matching allowed. Mirrors iOS `testNoMatchDescriptionDetector`.
 */
class KilterMatchTest {

    @Test
    fun detectsNoMatchNote() {
        assertTrue(kilterDescriptionForbidsMatching("No matching"))
        assertTrue(kilterDescriptionForbidsMatching("Fun jug haul. NO MATCH on the start."))
        assertTrue(kilterDescriptionForbidsMatching("crimpy — no-match"))
        assertTrue(kilterDescriptionForbidsMatching("nomatch"))
        assertFalse(kilterDescriptionForbidsMatching("Great climb, match the finish."))
        assertFalse(kilterDescriptionForbidsMatching(""))
        // Must NOT fire inside ordinary words / a trailing-letter form (word-boundary matching).
        assertFalse(kilterDescriptionForbidsMatching("piano matched perfectly"))
        assertFalse(kilterDescriptionForbidsMatching("Casino match on the dyno"))
        assertFalse(kilterDescriptionForbidsMatching("volcano matches the vibe"))
        assertFalse(kilterDescriptionForbidsMatching("no matches found in the log"))
    }
}
