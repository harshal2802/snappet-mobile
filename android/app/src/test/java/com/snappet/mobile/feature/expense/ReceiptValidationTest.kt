package com.snappet.mobile.feature.expense

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * JVM unit tests for the pure receipt cross-check ([ReceiptValidation]). Mirrors the iOS
 * `ReceiptValidationTests`.
 */
class ReceiptValidationTest {

    private fun item(name: String, price: Double, who: List<String>) = ReceiptItem(name, price, who)

    private fun report(
        items: List<ReceiptItem>,
        tax: Double = 0.0,
        discount: Double = 0.0,
        subtotal: Double? = null,
        detectedTax: Double? = null,
        total: Double? = null,
        count: Int? = null,
    ): ReceiptValidation.Report {
        val result = ReceiptSplit.compute(items, tax, discount, listOf("Alice", "Bob"))
        return ReceiptValidation.validate(
            result, subtotal, detectedTax, total, count, items.count { it.price > 0 },
        )
    }

    private fun status(r: ReceiptValidation.Report, id: String) =
        r.checks.first { it.id == id }.status

    @Test fun balancedWhenItemsTaxMatchTotal() {
        val r = report(listOf(item("A", 10.0, listOf("Alice")), item("B", 20.0, listOf("Bob"))),
            tax = 3.0, subtotal = 30.0, total = 33.0)
        assertEquals(ReceiptValidation.Status.PASS, r.overall)
        assertEquals(ReceiptValidation.Status.PASS, status(r, "total"))
        assertEquals(ReceiptValidation.Status.PASS, status(r, "subtotal"))
    }

    @Test fun failsWhenTotalDoesNotReconcile() {
        val r = report(listOf(item("A", 10.0, listOf("Alice")), item("B", 20.0, listOf("Bob"))),
            tax = 3.0, total = 45.0)
        assertEquals(ReceiptValidation.Status.FAIL, r.overall)
        assertEquals(ReceiptValidation.Status.FAIL, status(r, "total"))
    }

    @Test fun discountIncludedInReconciliation() {
        val r = report(listOf(item("A", 10.0, listOf("Alice")), item("B", 10.0, listOf("Bob"))),
            discount = 4.0, total = 16.0)
        assertEquals(ReceiptValidation.Status.PASS, status(r, "total"))
    }

    @Test fun warnsWhenNoTotalDetected() {
        val r = report(listOf(item("A", 10.0, listOf("Alice"))))
        assertEquals(ReceiptValidation.Status.WARN, status(r, "total"))
        assertEquals(ReceiptValidation.Status.WARN, r.overall)
    }

    @Test fun unassignedItemsWarn() {
        val r = report(listOf(item("A", 10.0, listOf("Alice")), item("B", 6.0, emptyList())), total = 16.0)
        assertEquals(ReceiptValidation.Status.PASS, status(r, "total"))
        assertEquals(ReceiptValidation.Status.WARN, status(r, "unassigned"))
        assertEquals(ReceiptValidation.Status.WARN, r.overall)
    }

    @Test fun itemCountMismatchWarns() {
        val r = report(listOf(item("A", 10.0, listOf("Alice"))), total = 10.0, count = 3)
        assertEquals(ReceiptValidation.Status.WARN, status(r, "count"))
    }

    @Test fun taxMismatchWarns() {
        val r = report(listOf(item("A", 30.0, listOf("Alice"))), tax = 3.0, detectedTax = 5.0, total = 33.0)
        assertEquals(ReceiptValidation.Status.WARN, status(r, "tax"))
    }
}
