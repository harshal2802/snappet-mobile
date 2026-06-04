package com.snappet.mobile.feature.expense

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * JVM unit tests that an itemized [ExpenseRecord] flows through [SettleUp.balances] correctly: the
 * payer is credited the grand total, each person is debited their [ReceiptSplit] slice, and the
 * group nets to zero. Mirrors the iOS `SettleUpReceiptTests`.
 */
class SettleUpReceiptTest {

    private val group = listOf("Alice", "Bob", "Cara")

    private fun balance(balances: List<SettleUp.Balance>, name: String) =
        balances.first { it.name == name }.net

    private fun receipt(
        payer: String,
        items: List<ReceiptItem>,
        tax: Double = 0.0,
        discount: Double = 0.0,
    ) = ExpenseRecord(
        groupId = "g",
        title = "Receipt",
        amount = ReceiptSplit.compute(items, tax, discount, group).grandTotal,
        payer = payer,
        participantsRaw = ExpenseRecord.joinParticipants(group),
        date = 0L,
        itemsRaw = ExpenseRecord.encodeItems(items),
        taxAmount = tax,
        discountAmount = discount,
    )

    @Test fun receiptCreditsPayerAndDebitsSharers() {
        val r = receipt(
            "Alice",
            listOf(
                ReceiptItem("Pizza", 30.0, group),
                ReceiptItem("Beer", 20.0, listOf("Bob", "Cara")),
            ),
        )
        val b = SettleUp.balances(group, listOf(r))
        assertEquals(40.0, balance(b, "Alice"), 0.0001)
        assertEquals(-20.0, balance(b, "Bob"), 0.0001)
        assertEquals(-20.0, balance(b, "Cara"), 0.0001)
        assertEquals(0.0, b.sumOf { it.net }, 0.0001)
    }

    @Test fun receiptWithTaxAndDiscountNetsToZero() {
        val items = (0 until 25).map { i ->
            ReceiptItem("Item $i", (i % 5) + 1.49, group.take((i % 3) + 1))
        }
        val r = receipt("Bob", items, tax = 6.13, discount = 4.20)
        val b = SettleUp.balances(group, listOf(r))
        assertEquals(0.0, b.sumOf { it.net }, 0.0001)
    }

    @Test fun evenSplitStillWorksAlongsideReceipts() {
        val even = ExpenseRecord(
            groupId = "g", title = "Cab", amount = 30.0, payer = "Cara",
            participantsRaw = ExpenseRecord.joinParticipants(group), date = 0L,
        )
        val b = SettleUp.balances(group, listOf(even))
        assertEquals(20.0, balance(b, "Cara"), 0.0001)
        assertEquals(-10.0, balance(b, "Alice"), 0.0001)
    }

    @Test fun itemEncodingRoundTrips() {
        val items = listOf(
            ReceiptItem("Org Arugula", 4.89, listOf("Alice", "Bob")),
            ReceiptItem("Tilapia", 19.29, listOf("Cara")),
            ReceiptItem("Unassigned", 1.00, emptyList()),
        )
        val decoded = ExpenseRecord.decodeItems(ExpenseRecord.encodeItems(items))
        assertEquals(items, decoded)
    }
}
