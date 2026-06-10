package com.snappet.mobile.feature.expense

import com.snappet.mobile.feature.habit.HabitStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #88's "recompute correctly after deletion" criterion, locked at the pure layer:
 * the stats/balance functions are pure over their input lists, so deleting a row and
 * re-running them must yield exactly the no-row result — no hidden accumulation.
 * Plus the new participant-suggestion helper's truth table.
 */
class CrudRecomputeTest {

    private fun expense(group: String, title: String, amount: Double, payer: String,
                        participants: List<String>, settlement: Boolean = false) =
        ExpenseRecord(groupId = group, title = title, amount = amount, payer = payer,
                      participantsRaw = participants.joinToString(","), date = 0,
                      isSettlement = settlement)

    @Test
    fun balancesRecomputeAfterDeletingASettlement() {
        val people = listOf("Alice", "Bob")
        val dinner = expense("g", "Dinner", 100.0, "Alice", people)
        val settle = expense("g", "Settle", 50.0, "Bob", listOf("Alice"), settlement = true)

        // With the settlement: the pair is even.
        val settled = SettleUp.balances(people, listOf(dinner, settle))
        assertTrue(settled.all { kotlin.math.abs(it.net) < 0.01 })

        // Delete the (typo'd) settlement: Bob owes Alice 50 again — exactly the
        // pre-settlement state, not some accumulated remnant.
        val reverted = SettleUp.balances(people, listOf(dinner))
        assertEquals(50.0, reverted.first { it.name == "Alice" }.net, 0.01)
        assertEquals(-50.0, reverted.first { it.name == "Bob" }.net, 0.01)
        val transfers = SettleUp.transfers(reverted)
        assertEquals(1, transfers.size)
        assertEquals("Bob", transfers[0].debtor)
    }

    @Test
    fun balancesRecomputeAfterDeletingAnExpense() {
        val people = listOf("Alice", "Bob")
        val a = expense("g", "Dinner", 100.0, "Alice", people)
        val b = expense("g", "Taxi", 30.0, "Bob", people)
        val withBoth = SettleUp.balances(people, listOf(a, b))
        assertEquals(35.0, withBoth.first { it.name == "Alice" }.net, 0.01)

        val afterDelete = SettleUp.balances(people, listOf(a))
        assertEquals(50.0, afterDelete.first { it.name == "Alice" }.net, 0.01)
    }

    @Test
    fun streakRecomputesAfterDeletingAHabitsCompletions() {
        val day = 86_400_000L
        val today = HabitStats.startOfDay(System.currentTimeMillis())
        val days = setOf(today, today - day, today - 2 * day)
        assertEquals(3, HabitStats.streak(days))
        // Habit deleted → its completions go with it → streak math sees nothing.
        assertEquals(0, HabitStats.streak(emptySet()))
    }

    @Test
    fun participantSuggestionsDedupeAcrossGroups() {
        val names = SettleUp.participantSuggestions(
            listOf(listOf("Alice", "Bob"), listOf(" alice ", "Cleo", "")))
        assertEquals(listOf("Alice", "Bob", "Cleo"), names)
    }
}
