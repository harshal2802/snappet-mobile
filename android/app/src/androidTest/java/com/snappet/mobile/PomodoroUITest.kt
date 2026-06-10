package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walkthrough of the Pomodoro mini-app: open it from the App Library, exercise start/pause/reset,
 * open History, and confirm a settings change persists across a relaunch. Mirrors the iOS
 * `PomodoroUITests`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class PomodoroUITest : SuiteTest() {

    @Test
    fun timerControlsAndHistory() {
        launch()
        openModule("pomodoro")

        composeRule.onNodeWithTag("pomodoro.timeRemaining").assertIsDisplayed()

        composeRule.onNodeWithTag("pomodoro.start").performClick()
        composeRule.onNodeWithTag("pomodoro.pause").assertIsDisplayed()
        composeRule.onNodeWithTag("pomodoro.pause").performClick()

        composeRule.onNodeWithTag("pomodoro.reset").performClick()
        composeRule.onNodeWithTag("pomodoro.start").assertIsDisplayed()

        // Open History via the toolbar button and confirm the screen loads.
        composeRule.onNodeWithTag("pomodoro.history").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("History").assertIsDisplayed()

        // Back out to the timer root.
        tapBack()
        composeRule.onNodeWithTag("pomodoro.start").assertIsDisplayed()
    }

    /** Issue #85: the engine is app-owned — leaving the module must not kill a running session. */
    @Test
    fun timerSurvivesLeavingTheModule() {
        launch()
        openModule("pomodoro")

        composeRule.onNodeWithTag("pomodoro.start").performClick()
        composeRule.onNodeWithTag("pomodoro.pause").assertIsDisplayed()

        // Back out to the App Library (this used to dispose the remember{}-scoped timer),
        // then come back: the session must still be running.
        tapBack()
        composeRule.onNodeWithTag("appLibraryGrid").assertIsDisplayed()
        openModule("pomodoro")
        composeRule.onNodeWithTag("pomodoro.pause").assertIsDisplayed()

        // Clean up so later tests start idle.
        composeRule.onNodeWithTag("pomodoro.pause").performClick()
        composeRule.onNodeWithTag("pomodoro.reset").performClick()
    }

    @Test
    fun settingsPersistAcrossRelaunch() {
        var scenario = launch()
        openModule("pomodoro")

        composeRule.onNodeWithTag("pomodoro.settings").performClick()
        composeRule.onNodeWithTag("pomodoro.focusStepper").assertIsDisplayed()

        val before = textOf("pomodoro.focusValue")
        composeRule.onNodeWithTag("pomodoro.focusStepper.inc").performClick()
        val afterChange = textOf("pomodoro.focusValue")
        assertNotEquals("incrementing should change the focus length", before, afterChange)
        composeRule.onNodeWithTag("pomodoro.settings.done").performClick()

        // Relaunch: a fresh in-memory Room store, but settings live in SharedPreferences and persist.
        scenario.close()
        scenario = launch()
        openModule("pomodoro")
        composeRule.onNodeWithTag("pomodoro.settings").performClick()
        val afterRelaunch = textOf("pomodoro.focusValue")
        assertEquals("focus length should persist across relaunch", afterChange, afterRelaunch)
    }
}
