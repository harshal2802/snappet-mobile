package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Walkthrough of the Budget mini-app: add a category, log a transaction, edit it, then step to the
 * previous month and back, and open the 6-month trends chart. Asserts the month label changes and
 * the next-month chevron re-enables when viewing a past month. Mirrors the iOS
 * `BudgetUITests.testEditTransactionAndMonthSwitch`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class BudgetUITest : SuiteTest() {

    @Test
    fun editTransactionAndMonthSwitch() {
        launch()
        openModule("budget")

        // Seed a category (empty state on a fresh in-memory store).
        composeRule.onAllNodesWithTag("budget.addCategory")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("Name").performTextInput("Groceries")
        composeRule.onNodeWithTag("Amount").performTextInput("400")
        composeRule.onNodeWithTag("Save").performClick()
        composeRule.waitForIdle()

        // The month header should now render; capture its label.
        composeRule.onNodeWithTag("budget.monthLabel").assertIsDisplayed()
        val currentMonth = textOf("budget.monthLabel")

        // Add a transaction against the category via the Add menu.
        composeRule.onNodeWithTag("Add").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("budget.addTxn").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("budget.txnAmount").performTextInput("50")
        composeRule.onNodeWithTag("budget.txnSave").performClick()
        composeRule.waitForIdle()

        // Open the category's transaction list and edit the transaction.
        composeRule.onNodeWithTag("budget.category.Groceries").performClick()
        composeRule.waitForIdle()
        composeRule.onAllNodesWithTag("budget.editTxn")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("budget.txnAmount").performTextClearance()
        composeRule.onNodeWithTag("budget.txnAmount").performTextInput("75")
        composeRule.onNodeWithTag("budget.txnSave").performClick()
        composeRule.waitForIdle()

        // Back to the root from the category list.
        tapBack()

        // Step to the previous month — the label must change (the switcher re-scopes the view).
        composeRule.onNodeWithTag("budget.prevMonth").performClick()
        composeRule.waitForIdle()
        val prevMonth = textOf("budget.monthLabel")
        assertNotEquals("stepping back should change the displayed month", currentMonth, prevMonth)

        // Viewing a past month offers forward navigation: the next chevron is now enabled.
        composeRule.onNodeWithTag("budget.nextMonth").assertIsEnabled()
        composeRule.onNodeWithTag("budget.nextMonth").performClick()
        composeRule.waitForIdle()

        // The trends screen should be reachable and render its chart.
        composeRule.onNodeWithTag("budget.trends").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("budget.trendsChart").assertIsDisplayed()
    }
}
