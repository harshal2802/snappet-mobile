package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * UI flow for the Journal mini-app's tags + search feature: open Journal from the App Library,
 * create two entries (one carrying a unique tag), then search by that tag and assert the list
 * filters down to the tagged entry. Clearing the search restores the full list. Mirrors the iOS
 * `JournalUITests`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class JournalUITest : SuiteTest() {

    /** Create one entry with the given title and optional tag. */
    private fun createEntry(title: String, tag: String?) {
        composeRule.onAllNodesWithTag("journal.add").onFirst().performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("journal.titleField").performTextInput(title)
        if (tag != null) {
            // The trailing comma commits the tag into a chip.
            composeRule.onNodeWithTag("journal.tagField").performTextInput("$tag,")
        }

        composeRule.onNodeWithTag("journal.save").performClick()
        composeRule.waitForIdle()
    }

    @Test
    fun tagAndSearchFlow() {
        launch()
        openModule("journal")

        composeRule.onNodeWithText("Journal").assertIsDisplayed()

        // Unique tokens so assertions are independent of any pre-existing store contents.
        val unique = System.nanoTime().toString()
        val taggedTitle = "Tagged-$unique"
        val plainTitle = "Plain-$unique"
        val tag = "trip$unique"

        createEntry(title = taggedTitle, tag = tag)
        createEntry(title = plainTitle, tag = null)

        // Both entries should be listed.
        composeRule.onNodeWithText(taggedTitle).assertIsDisplayed()
        composeRule.onNodeWithText(plainTitle).assertIsDisplayed()

        // Search by the unique tag -> only the tagged entry should remain.
        composeRule.onNodeWithTag("journal.search").performTextInput(tag)
        composeRule.waitForIdle()
        composeRule.onNodeWithText(taggedTitle).assertIsDisplayed()
        composeRule.onNodeWithText(plainTitle).assertDoesNotExist()

        // Clear the search -> both entries return.
        composeRule.onNodeWithTag("journal.search").performTextClearance()
        composeRule.waitForIdle()
        composeRule.onNodeWithText(taggedTitle).assertIsDisplayed()
        composeRule.onNodeWithText(plainTitle).assertIsDisplayed()
    }
}
