package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Smoke test: every mini-app opens from the App Library via its card — verifying the shared
 * registry / navigation entry works for all 8 modules. Mirrors the iOS `SuiteSmokeTests`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class SuiteSmokeTest : SuiteTest() {

    @Test
    fun everySuiteAppOpens() {
        launch()
        openApps()

        val ids = listOf("workout", "workout-log", "pomodoro", "habit", "journal", "tip", "expense", "budget")
        for (id in ids) {
            composeRule.onNodeWithTag("appLibraryGrid").performScrollToNode(hasTestTag("moduleCard.$id"))
            composeRule.onNodeWithTag("moduleCard.$id").performClick()
            composeRule.waitForIdle()

            // Navigated into the module → the back arrow appears.
            composeRule.onNodeWithTag("BackButton").assertIsDisplayed()
            tapBack()
            openApps()
        }
    }
}
