package com.snappet.mobile.feature.expense

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit tests for the pure itemized-receipt split math ([ReceiptSplit]). The headline guarantee
 * is penny-perfect closure: each column is reconciled so the per-person totals sum exactly to the
 * grand total. Mirrors the iOS `ReceiptSplitTests`.
 */
class ReceiptSplitTest {

    private fun item(name: String, price: Double, who: List<String>) = ReceiptItem(name, price, who)

    private fun share(r: ReceiptSplit.Result, name: String) =
        r.perPerson.first { it.name == name }

    @Test fun sharedItemSplitsEvenly() {
        val r = ReceiptSplit.compute(listOf(item("Pizza", 20.0, listOf("Alice", "Bob"))), order = listOf("Alice", "Bob"))
        assertEquals(10.0, share(r, "Alice").total, 0.0001)
        assertEquals(10.0, share(r, "Bob").total, 0.0001)
        assertEquals(20.0, r.grandTotal, 0.0001)
    }

    @Test fun itemsChargedToTheirOwnAssignees() {
        val r = ReceiptSplit.compute(
            listOf(
                item("Shared", 10.0, listOf("Alice", "Bob")),
                item("Bob only", 20.0, listOf("Bob")),
            ),
            order = listOf("Alice", "Bob"),
        )
        assertEquals(5.0, share(r, "Alice").total, 0.0001)
        assertEquals(25.0, share(r, "Bob").total, 0.0001)
        assertEquals(30.0, r.itemsSubtotal, 0.0001)
    }

    @Test fun taxIsProportional() {
        val r = ReceiptSplit.compute(
            listOf(item("A", 5.0, listOf("Alice")), item("B", 25.0, listOf("Bob"))),
            taxAmount = 3.0, order = listOf("Alice", "Bob"),
        )
        assertEquals(0.50, share(r, "Alice").tax, 0.0001)
        assertEquals(2.50, share(r, "Bob").tax, 0.0001)
        assertEquals(33.0, r.grandTotal, 0.0001)
    }

    @Test fun discountIsCreditedProportionally() {
        val r = ReceiptSplit.compute(
            listOf(item("A", 10.0, listOf("Alice")), item("B", 10.0, listOf("Bob"))),
            discountAmount = 4.0, order = listOf("Alice", "Bob"),
        )
        assertEquals(2.0, share(r, "Alice").discount, 0.0001)
        assertEquals(8.0, share(r, "Alice").total, 0.0001)
        assertEquals(16.0, r.grandTotal, 0.0001)
    }

    @Test fun threeWaySplitReconcilesToExactTotal() {
        val r = ReceiptSplit.compute(
            listOf(item("Cab", 10.0, listOf("Alice", "Bob", "Cara"))),
            order = listOf("Alice", "Bob", "Cara"),
        )
        val sum = r.perPerson.sumOf { it.total }
        assertEquals(10.0, sum, 0.0001)
        for (s in r.perPerson) assertTrue("got ${s.total}", s.total == 3.33 || s.total == 3.34)
    }

    @Test fun rowsAreInternallyConsistent() {
        val r = ReceiptSplit.compute(
            listOf(
                item("A", 7.77, listOf("Alice", "Bob", "Cara")),
                item("B", 13.13, listOf("Bob", "Cara")),
            ),
            taxAmount = 2.05, discountAmount = 1.11, order = listOf("Alice", "Bob", "Cara"),
        )
        for (s in r.perPerson) {
            assertEquals(s.total, s.itemsSubtotal + s.tax - s.discount, 0.0001)
        }
        assertEquals(r.grandTotal, r.perPerson.sumOf { it.total }, 0.0001)
    }

    @Test fun unassignedItemsAreNotCharged() {
        val r = ReceiptSplit.compute(
            listOf(item("Mine", 10.0, listOf("Alice")), item("Nobody's", 6.0, emptyList())),
            order = listOf("Alice"),
        )
        assertEquals(6.0, r.unassignedSubtotal, 0.0001)
        assertEquals(10.0, share(r, "Alice").total, 0.0001)
        assertEquals(1, r.perPerson.size)
        assertEquals(10.0, r.grandTotal, 0.0001)
    }

    @Test fun respectsRequestedOrderThenAppendsExtras() {
        val r = ReceiptSplit.compute(
            listOf(item("A", 1.0, listOf("Zed")), item("B", 1.0, listOf("Alice"))),
            order = listOf("Alice", "Bob"),
        )
        assertEquals(listOf("Alice", "Zed"), r.perPerson.map { it.name })
    }

    @Test fun manyItemsAndTaxStillCloseExactly() {
        val people = listOf("Alice", "Bob", "Cara")
        val items = (0 until 40).map { i ->
            item("Item $i", (i % 7) + 0.99, people.take((i % 3) + 1))
        }
        val r = ReceiptSplit.compute(items, taxAmount = 14.01, discountAmount = 17.50, order = people)
        assertEquals(r.grandTotal, r.perPerson.sumOf { it.total }, 0.0001)
        assertEquals(14.01, r.tax, 0.0001)
        assertEquals(17.50, r.discount, 0.0001)
    }
}
