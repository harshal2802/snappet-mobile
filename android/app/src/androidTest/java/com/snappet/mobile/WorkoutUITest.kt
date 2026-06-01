package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end walkthrough of the Workout Tracker mini-app: open it, visit each section, drill into
 * an exercise detail and a routine, run the player to completion, and confirm the finished session
 * lands on the dashboard + shows up under History. Mirrors the iOS `WorkoutWalkthroughTests`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class WorkoutUITest : SuiteTest() {

    private fun exists(text: String): Boolean =
        composeRule.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    private fun existsTag(tag: String): Boolean =
        composeRule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun fullWalkthrough() {
        launch()
        openModule("workout-log")

        // Visit each section.
        for (s in listOf("Exercises", "Routines", "History", "Settings")) {
            composeRule.onNodeWithTag("workout.section.$s").performClick()
            composeRule.waitForIdle()
        }

        // Exercises: open the first exercise → its detail shows "Category"; then back.
        composeRule.onNodeWithTag("workout.section.Exercises").performClick()
        composeRule.waitForIdle()
        composeRule.onAllNodesWithTag("exerciseRow")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Category").assertIsDisplayed()
        tapBack()

        // Routines: open the first routine → detail shows "Start Workout" → drive the player.
        composeRule.onNodeWithTag("workout.section.Routines").performClick()
        composeRule.waitForIdle()
        composeRule.onAllNodesWithTag("routineRow")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Start Workout").assertIsDisplayed()
        composeRule.onNodeWithText("Start Workout").performClick()
        composeRule.waitForIdle()

        drivePlayerToDone()
        composeRule.waitForIdle()

        // Finishing a saved workout lands back on the dashboard.
        assertTrue(
            "finishing a saved workout should land on the dashboard",
            exists("Day streak") || exists("Workouts"),
        )

        // History now holds the finished session.
        composeRule.onNodeWithTag("workout.section.History").performClick()
        composeRule.waitForIdle()
        assertTrue(
            "the finished workout should appear in History",
            exists("5-Minute Mobility") || existsTag("historyRow"),
        )
    }

    private fun drivePlayerToDone() {
        repeat(40) {
            composeRule.waitForIdle()
            when {
                exists("Finish") -> {
                    composeRule.onNodeWithText("Finish").performClick()
                    return
                }
                exists("Skip rest") -> composeRule.onNodeWithText("Skip rest").performClick()
                exists("Complete & finish") -> composeRule.onNodeWithText("Complete & finish").performClick()
                exists("Complete set") -> composeRule.onNodeWithText("Complete set").performClick()
                exists("Skip exercise") -> composeRule.onNodeWithText("Skip exercise").performClick()
                else -> return@repeat
            }
        }
        composeRule.waitForIdle()
        if (exists("Finish")) composeRule.onNodeWithText("Finish").performClick()
    }
}
