package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappet.mobile.core.TestHooks
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walkthrough of the Kilter mini-app's Phase-1 flow: open the catalog, open a climb, log a send, and
 * confirm it lands in History; and save a climb and confirm it shows under the Saved filter. Mirrors
 * the iOS `KilterUITests`.
 *
 * Issue #42: the app no longer ships a catalog, so the browse tests set
 * `TestHooks.installKilterCatalogFixture` to install the **synthetic** fixture (`KilterCatalogFixture`,
 * zero Aurora data) before the module opens — standing in for a real user import. A separate test
 * leaves the hook off and asserts the opt-in sync screen.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class KilterUITest : SuiteTest() {

    @After
    fun clearCatalogHook() {
        TestHooks.installKilterCatalogFixture = false
    }

    private fun launchWithCatalog() {
        TestHooks.installKilterCatalogFixture = true
        launch()
    }

    private fun openFirstClimb() {
        openModule("kilter")
        composeRule.waitUntil(timeoutMillis = 8_000) {
            composeRule.onAllNodesWithTag("kilter.climbRow").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("kilter.climbRow")[0].performClick()
        composeRule.waitForIdle()
    }

    @Test
    fun emptyStateShowsCatalogSyncScreen() {
        TestHooks.installKilterCatalogFixture = false
        launch()
        openModule("kilter")
        composeRule.waitUntil(timeoutMillis = 6_000) {
            composeRule.onAllNodesWithTag("kilter.catalog.import").fetchSemanticsNodes().isNotEmpty()
        }
        // Both install paths are offered; Download leads (issue #94).
        composeRule.onNodeWithTag("kilter.catalog.sync").assertIsDisplayed()
        composeRule.onNodeWithTag("kilter.catalog.import").assertIsDisplayed()
        // No climbs are listed in the opt-in empty state.
        assert(composeRule.onAllNodesWithTag("kilter.climbRow").fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun loggingASendAppearsInHistory() {
        launchWithCatalog()
        openFirstClimb()

        composeRule.onNodeWithTag("kilter.log.sent").performScrollTo().performClick()
        composeRule.waitForIdle()

        // History lives on the catalog top bar, so step back out of the climb detail first.
        tapBack()
        composeRule.onNodeWithTag("kilter.history").performClick()
        // The redesigned History is content-first: the session timeline + consistency viz lead, and the
        // flat "Ascents" leaf list (carrying kilter.historyRow) sits below — so a just-logged ascent's row
        // is a lazy item off the first screen. Scroll the list to it, then assert it's there.
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("kilter.history.list").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithTag("kilter.history.list").performScrollToNode(hasTestTag("kilter.historyRow"))
        composeRule.onAllNodesWithTag("kilter.historyRow")[0].assertIsDisplayed()
    }

    @Test
    fun savingAClimbShowsUnderSavedFilter() {
        launchWithCatalog()
        openFirstClimb()

        composeRule.onNodeWithTag("kilter.favorite").performClick()
        composeRule.waitForIdle()
        tapBack()

        composeRule.onNodeWithTag("kilter.savedToggle").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("kilter.climbRow").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("kilter.climbRow")[0].assertIsDisplayed()
    }
}
