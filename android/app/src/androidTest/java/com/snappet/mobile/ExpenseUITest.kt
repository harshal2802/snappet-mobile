package com.snappet.mobile

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
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
 * End-to-end UI flow for Split Expenses: create a group, add an expense, edit its amount, then
 * record a manual settlement equal to the suggested transfer and assert the pair clears. Mirrors
 * the iOS `ExpenseUITests.testEditAndSettleFlow`.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ExpenseUITest : SuiteTest() {

    @Test
    fun editAndSettleFlow() {
        launch()
        openModule("expense")

        // Create a group "Trip" with participants Alice and Bob.
        composeRule.onNodeWithTag("expense.newGroup").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("expense.group.name").performTextInput("Trip")
        composeRule.onNodeWithTag("expense.group.participant.0").performTextInput("Alice")
        composeRule.onNodeWithTag("expense.group.participant.1").performTextInput("Bob")
        composeRule.onNodeWithTag("expense.group.save").performClick()
        composeRule.waitForIdle()

        // Open the group.
        composeRule.onAllNodesWithTag("expenseGroupRow")[0].performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("expense.groupActions").assertIsDisplayed()

        // Add an expense: Alice (default payer) paid 100, split between both -> Bob owes Alice 50.
        composeRule.onNodeWithTag("expense.groupActions").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("expense.newExpense").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("expense.expense.title").performTextInput("Dinner")
        composeRule.onNodeWithTag("expense.expense.amount").performTextInput("100")
        composeRule.onNodeWithTag("expense.expense.save").performClick()
        composeRule.waitForIdle()

        // The settle-up plan should now suggest Bob owes Alice.
        composeRule.onNodeWithText("Bob owes Alice").assertIsDisplayed()

        // Edit the expense amount to 60 -> Bob now owes Alice 30.
        composeRule.onNodeWithText("Dinner").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("expense.expense.amount").performTextClearance()
        composeRule.onNodeWithTag("expense.expense.amount").performTextInput("60")
        composeRule.onNodeWithTag("expense.expense.save").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Bob owes Alice").assertIsDisplayed()

        // Record a settlement: Bob pays Alice 30 -> the pair clears.
        composeRule.onNodeWithTag("expense.groupActions").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("expense.settle").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("expense.settle.payer").performClick()
        composeRule.onNodeWithTag("expense.settle.payer.option.Bob").performClick()
        composeRule.onNodeWithTag("expense.settle.recipient").performClick()
        composeRule.onNodeWithTag("expense.settle.recipient.option.Alice").performClick()
        composeRule.onNodeWithTag("expense.settle.amount").performTextClearance()
        composeRule.onNodeWithTag("expense.settle.amount").performTextInput("30")
        composeRule.onNodeWithTag("expense.settle.save").performClick()
        composeRule.waitForIdle()

        // A settlement equal to the suggested transfer should clear the pair.
        composeRule.onNodeWithText("All settled up").assertIsDisplayed()
    }
}
