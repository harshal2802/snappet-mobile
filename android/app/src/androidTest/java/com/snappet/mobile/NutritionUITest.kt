package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walks through the Nutrition mini-app on a fresh in-memory store:
 * opens the module → taps Add for Breakfast → searches → selects → logs → asserts
 * diary is visible → switches to History and Goals tabs.
 * Mirrors the iOS `NutritionUITests.testSearchLogAndDiary`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class NutritionUITest : SuiteTest() {

    @Test
    fun searchLogAndDiary() {
        launch()
        openModule("nutrition")

        // Add food to Breakfast.
        composeRule.onNodeWithTag("nutrition.addFood.breakfast").performClick()
        composeRule.waitForIdle()

        // Search for a seed item.
        composeRule.onNodeWithTag("nutrition.searchField").performTextInput("Chicken")
        composeRule.waitForIdle()

        // Select the first result.
        composeRule.onAllNodesWithTag("nutrition.foodResult")[0].performClick()
        composeRule.waitForIdle()

        // Confirm add to diary.
        composeRule.onNodeWithTag("nutrition.addToDiary").performClick()
        composeRule.waitForIdle()

        // Diary should show the ring, macro bars, and the Breakfast section.
        composeRule.onNodeWithTag("nutrition.budgetRing").assertIsDisplayed()
        composeRule.onNodeWithTag("nutrition.macroBars").assertIsDisplayed()
        composeRule.onNodeWithTag("nutrition.meal.breakfast").assertIsDisplayed()

        // Switch to History tab.
        composeRule.onNodeWithTag("nutrition.tab.history").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("nutrition.history").assertIsDisplayed()

        // Switch to Goals tab.
        composeRule.onNodeWithTag("nutrition.tab.goals").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("nutrition.saveGoals").assertIsDisplayed()
    }
}
