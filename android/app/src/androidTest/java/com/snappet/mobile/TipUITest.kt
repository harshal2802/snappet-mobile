package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walkthrough of the Tip mini-app: commit a calculation and confirm it lands in History, and edit a
 * preset percentage and confirm the preset button reflects it. Mirrors the iOS `TipUITests`. Presets
 * persist in SharedPreferences across runs, so the edit test asserts a relative +1% change.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class TipUITest : SuiteTest() {

    @Test
    fun committingCalculationAppearsInHistory() {
        launch()
        openModule("tip")

        composeRule.onNodeWithTag("tip.bill").performTextInput("42.50")
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("tip.preset.1").performScrollTo().performClick()
        // The commit button sits at the bottom of a scrollable column — scroll it into view first.
        composeRule.onNodeWithTag("tip.commit").performScrollTo().performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("tip.history").performClick()
        // The commit persists via an async coroutine; wait for the reactive list to emit the row.
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("tip.historyRow").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("tip.historyRow")[0].assertIsDisplayed()
    }

    @Test
    fun editingPresetUpdatesButton() {
        launch()
        openModule("tip")

        val before = textOf("tip.preset.0").trim().removeSuffix("%").toInt()

        composeRule.onNodeWithTag("tip.editPresets").performClick()
        composeRule.onNodeWithTag("tip.presetEdit.0.inc").performClick()
        composeRule.onNodeWithTag("tip.presetEdit.done").performClick()
        composeRule.waitForIdle()

        val after = textOf("tip.preset.0").trim().removeSuffix("%").toInt()
        assertEquals(before + 1, after)
    }
}
