package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.percentOffset
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.snappet.mobile.core.TestHooks
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented UI coverage for the **create-a-climb** feature (Android port of iOS PRs #63–#65): opening
 * the editor, the disabled-until-valid Save, drawing a climb on the editable board → saving → finding it
 * under the Mine filter → the duplicate guard on re-save, and the ✨ Generate tab's download prompt. Runs
 * on the emulator with the synthetic catalog fixture installed (issue #42).
 *
 * The create screen is a vertical scroller and the filter chips scroll horizontally, so targets are
 * `performScrollTo()`-d before use. The fixture board is a 5×5 hole grid (one placement per hole), so holds
 * are placed by tapping grid fractions (0.25 / 0.5 / 0.75): the center hole tapped 3× cycles to a finish,
 * three other holes once each become starts → a valid climb (≥4 holds, a start, a finish).
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class KilterCreateUITest : SuiteTest() {

    @After
    fun clearCatalogHook() {
        TestHooks.installKilterCatalogFixture = false
    }

    private fun openKilter() {
        TestHooks.installKilterCatalogFixture = true
        launch()
        openModule("kilter")
        composeRule.waitUntil(timeoutMillis = 8_000) {
            composeRule.onAllNodesWithTag("kilter.more").fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun openCreate() {
        openKilter()
        composeRule.onNodeWithTag("kilter.more").performClick()
        composeRule.onNodeWithTag("kilter.create").performClick()
        composeRule.waitForIdle()
    }

    /** Draw a valid climb: center hole ×3 → finish; three other holes ×1 → start. */
    private fun placeValidClimb() {
        val board = composeRule.onNodeWithTag("kilter.create.board")
        board.performScrollTo()
        composeRule.waitForIdle()
        repeat(3) {
            board.performTouchInput { click(percentOffset(0.5f, 0.5f)) }
            composeRule.waitForIdle()
        }
        for ((fx, fy) in listOf(0.25f to 0.25f, 0.75f to 0.75f, 0.75f to 0.25f)) {
            board.performTouchInput { click(percentOffset(fx, fy)) }
            composeRule.waitForIdle()
        }
    }

    @Test
    fun createScreenOpensWithModeAndDisabledSave() {
        openCreate()
        composeRule.onNodeWithTag("kilter.create.mode.MANUAL").assertIsDisplayed()
        composeRule.onNodeWithTag("kilter.create.mode.GENERATE").assertIsDisplayed()
        composeRule.onNodeWithTag("kilter.create.name").assertIsDisplayed()
        // Nothing placed → invalid + Save disabled.
        composeRule.onNodeWithTag("kilter.create.invalid").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("kilter.create.save").assertIsNotEnabled()
    }

    @Test
    fun generateTabShowsDownloadPrompt() {
        openCreate()
        composeRule.onNodeWithTag("kilter.create.mode.GENERATE").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("kilter.generate.download").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun mineFilterShowsEmptyStateInitially() {
        openKilter()
        composeRule.onNodeWithTag("kilter.mineToggle").performScrollTo().performClick()
        composeRule.waitForIdle()
        // No authored climbs yet → empty state, no climb rows.
        assert(composeRule.onAllNodesWithTag("kilter.climbRow").fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun manualCreateSavesAndAppearsUnderMine() {
        openCreate()
        placeValidClimb()
        composeRule.onNodeWithTag("kilter.create.valid").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("kilter.create.save").performScrollTo().assertIsEnabled().performClick()
        composeRule.waitForIdle()
        // onCreated opens the new climb's detail; back out and switch to Mine.
        tapBack()
        composeRule.onNodeWithTag("kilter.mineToggle").performScrollTo().performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("kilter.climbRow").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onAllNodesWithTag("kilter.climbRow")[0].assertIsDisplayed()
    }

    @Test
    fun reSavingSameClimbTriggersDuplicateGuard() {
        openCreate()
        placeValidClimb()
        composeRule.onNodeWithTag("kilter.create.save").performScrollTo().assertIsEnabled().performClick()
        composeRule.waitForIdle()
        tapBack()   // back on the catalog root

        // Author the identical climb again → the duplicate checker warns before saving.
        composeRule.onNodeWithTag("kilter.more").performClick()
        composeRule.onNodeWithTag("kilter.create").performClick()
        composeRule.waitForIdle()
        placeValidClimb()
        composeRule.onNodeWithTag("kilter.create.save").performScrollTo().performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("Climb already exists").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("Climb already exists").assertIsDisplayed()
    }
}
