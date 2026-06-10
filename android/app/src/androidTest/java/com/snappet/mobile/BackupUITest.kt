package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The Backup & restore surface (issue #84): reachable from the App Library's top bar,
 * renders both the Export and Import affordances, and backs out cleanly. The SAF
 * pickers + actual file round-trip are covered at the codec/manager layer
 * ([BackupRoundTripTest]) — a document picker can't be driven from a Compose test.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class BackupUITest : SuiteTest() {

    @Test
    fun backupScreenIsReachableAndRendersBothActions() {
        launch()
        composeRule.onNodeWithTag("tab.apps").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("library.backup").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("backup.export").assertIsDisplayed()
        composeRule.onNodeWithTag("backup.import").assertIsDisplayed()

        // Back returns to the library grid.
        composeRule.onNodeWithTag("backup.back").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("appLibraryGrid").assertIsDisplayed()
    }
}
