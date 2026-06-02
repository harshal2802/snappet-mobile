package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walkthrough of the Kilter mini-app's Phase-1 flow: open the catalog, open a climb, log a send, and
 * confirm it lands in History; and save a climb and confirm it shows under the Saved filter. Mirrors
 * the iOS `KilterUITests`. The bundled catalog ships in the APK, so it's present even with the fresh
 * in-memory store (which only resets user data).
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class KilterUITest : SuiteTest() {

    private fun openFirstClimb() {
        openModule("kilter")
        composeRule.waitUntil(timeoutMillis = 8_000) {
            composeRule.onAllNodesWithTag("kilter.climbRow").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("kilter.climbRow")[0].performClick()
        composeRule.waitForIdle()
    }

    @Test
    fun loggingASendAppearsInHistory() {
        launch()
        openFirstClimb()

        composeRule.onNodeWithTag("kilter.log.sent").performScrollTo().performClick()
        composeRule.waitForIdle()

        // History lives on the catalog top bar, so step back out of the climb detail first.
        tapBack()
        composeRule.onNodeWithTag("kilter.history").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("kilter.historyRow").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("kilter.historyRow")[0].assertIsDisplayed()
    }

    @Test
    fun savingAClimbShowsUnderSavedFilter() {
        launch()
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
