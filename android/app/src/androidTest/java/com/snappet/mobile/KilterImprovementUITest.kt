package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappet.mobile.core.TestHooks
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Render/no-crash smoke coverage for the three new first-class Kilter surfaces added in Wave C
 * (iOS parity): Your Climbs, Stats, and On the Board. Each test opens the catalog's overflow
 * ("More") menu, taps the screen's entry, and asserts the screen's own scaffold rendered.
 *
 * Mirrors [KilterUITest] / [KilterCreateUITest]: installs the synthetic catalog fixture
 * (`TestHooks.installKilterCatalogFixture`, issue #42) and a fresh in-memory store before
 * launching into the Kilter module. Because the store is fresh, every screen lands in its
 * empty state — so each assertion accepts the hero **or** the empty-state scaffold tag: this is
 * a "the screen rendered without crashing" check, not a data-row check.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class KilterImprovementUITest : SuiteTest() {

    @After
    fun clearCatalogHook() {
        TestHooks.installKilterCatalogFixture = false
    }

    /** Install the catalog, launch, open Kilter, and wait for the catalog top bar to settle. */
    private fun openKilter() {
        TestHooks.installKilterCatalogFixture = true
        launch()
        openModule("kilter")
        composeRule.waitUntil(timeoutMillis = 8_000) {
            composeRule.onAllNodesWithTag("kilter.more").fetchSemanticsNodes().isNotEmpty()
        }
    }

    /** Open the overflow ("More") menu, then tap one of its [entryTag] items. */
    private fun openMenuItem(entryTag: String) {
        composeRule.onNodeWithTag("kilter.more").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag(entryTag).fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag(entryTag).performClick()
        composeRule.waitForIdle()
    }

    /** Wait until any of [tags] is on screen (the screen settled into hero or empty state). */
    private fun assertScreenRendered(vararg tags: String) {
        composeRule.waitUntil(timeoutMillis = 8_000) {
            tags.any { tag ->
                composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
            }
        }
        assert(
            tags.any { tag ->
                composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
            },
        ) { "Expected one of $tags to render; none did." }
    }

    @Test
    fun yourClimbsScreenOpens() {
        openKilter()
        openMenuItem("kilter.yourClimbs.open")
        // Empty state is fine: the hero (with climbs) or the "Set a climb" CTA (empty) both prove
        // the Your Climbs scaffold rendered.
        assertScreenRendered("kilter.yourClimbs.hero", "kilter.yourClimbs.setClimb")
    }

    @Test
    fun statsScreenOpens() {
        openKilter()
        openMenuItem("kilter.stats.open")
        // Hero (with logged climbs) or the "No stats yet" empty scaffold — either means Stats rendered.
        assertScreenRendered("kilter.stats.hero", "kilter.stats.empty")
    }

    @Test
    fun onTheBoardScreenOpens() {
        openKilter()
        openMenuItem("kilter.board.open")
        // Hero (with lit climbs) or the "Nothing lit yet" empty scaffold — either means On the Board rendered.
        assertScreenRendered("kilter.board.hero", "kilter.board.empty")
    }
}
