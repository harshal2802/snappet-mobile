package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walkthrough of the Habit mini-app: create a habit, edit its name, then backfill a prior day via
 * the 7-day strip and confirm the streak + 30-day completion-rate labels render. Mirrors the iOS
 * `HabitUITests.testEditAndBackfillFlow`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class HabitUITest : SuiteTest() {

    @Test
    fun editAndBackfillFlow() {
        launch()
        openModule("habit")

        composeRule.onNodeWithText("Habits").assertIsDisplayed()

        // Create a habit named "Read".
        composeRule.onAllNodesWithTag("habit.add")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("habit.nameField").performTextInput("Read")
        composeRule.onNodeWithTag("habit.save").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("habit.row.0").assertIsDisplayed()
        composeRule.onNodeWithText("Read").assertIsDisplayed()

        // Edit the habit's name -> "Read Daily".
        composeRule.onAllNodesWithTag("habit.edit")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("habit.nameField").performTextClearance()
        composeRule.onNodeWithTag("habit.nameField").performTextInput("Read Daily")
        composeRule.onNodeWithTag("habit.save").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Read Daily").assertIsDisplayed()

        // Backfill yesterday (offset 1) then mark today (offset 0) -> a 2-day streak ending today.
        composeRule.onNodeWithTag("habit.day.1").performClick()
        composeRule.onNodeWithTag("habit.day.0").performClick()
        composeRule.waitForIdle()

        // A streak label should be shown, and the 30-day completion-rate label exists.
        composeRule.onNode(hasText("streak", substring = true, ignoreCase = true)).assertIsDisplayed()
        composeRule.onNodeWithTag("habit.rate.0").assertIsDisplayed()
    }
}
