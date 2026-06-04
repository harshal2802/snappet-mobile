package com.snappet.mobile.feature.expense

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit tests for the pure receipt-text parser ([ReceiptParser]), driven by real Costco lines.
 * Mirrors the iOS `ReceiptParserTests`.
 */
class ReceiptParserTest {

    @Test fun extractsItemsStrippingCodesAndFlags() {
        val text = """
            E 1932071 LIQUIDIV LLS 28.99 E
            2015573 CHSEBRGRCAP 11.99 A
            689917 KING HAWAII 5.59 E
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(listOf("LIQUIDIV LLS", "CHSEBRGRCAP", "KING HAWAII"), r.items.map { it.name })
        assertEquals(listOf(28.99, 11.99, 5.59), r.items.map { it.price })
        assertTrue(r.items.all { it.assignees.isEmpty() })
    }

    @Test fun instantSavingsBecomeDiscountNotItems() {
        val text = """
            F 1877320 VC SPF 50 19.99 A
            0000378710 / 1877320 4.00-A
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(1, r.items.size)
        assertEquals("VC SPF 50", r.items.first().name)
        assertEquals(4.00, r.discount, 0.0001)
    }

    @Test fun capturesTaxAndGrandTotal() {
        val text = """
            SUBTOTAL 605.09
            TAX 14.01
            **** TOTAL 619.10
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(14.01, r.tax ?: -1.0, 0.0001)
        assertEquals(619.10, r.total ?: -1.0, 0.0001)
        assertTrue(r.items.isEmpty())
    }

    @Test fun summaryAndPaymentRowsAreNotItems() {
        val text = """
            2027490 ORGAINA2 27.99 E
            SUBTOTAL 605.09
            TAX 14.01
            **** TOTAL 619.10
            Visa 619.10
            CHANGE 0.00
            TOTAL NUMBER OF ITEMS SOLD = 51
            AMOUNT: ${'$'}619.10
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(listOf("ORGAINA2"), r.items.map { it.name })
        assertEquals(27.99, r.items.first().price, 0.0001)
        assertEquals(619.10, r.total ?: -1.0, 0.0001)
    }

    @Test fun handlesAttachedTaxFlagAndCommas() {
        val r = ReceiptParser.parse("100 BIG TICKET 1,234.50 A")
        assertEquals("BIG TICKET", r.items.first().name)
        assertEquals(1234.50, r.items.first().price, 0.0001)
    }

    // Regression: tax must come from the authoritative "TOTAL TAX" line, not the last TAX-bearing
    // line (per-rate "% Tax" and "FSA TAX" lines would otherwise clobber it). See review Bug 1.
    @Test fun taxPrefersTotalTaxIgnoringComponentAndFsaLines() {
        val text = """
            SUBTOTAL 605.09
            TAX 14.01
            **** TOTAL 619.10
            A 10.25% Tax 6.81
            B 2.25% TAX 1.12
            E 1.25% TAX 6.08
            TOTAL TAX 14.01
            FSA TAX = 1.64
            FSA TOTAL = 17.63
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(14.01, r.tax ?: -1.0, 0.0001)
        assertEquals(619.10, r.total ?: -1.0, 0.0001)
        assertEquals(605.09, r.subtotal ?: -1.0, 0.0001)
    }

    @Test fun detectsSubtotalAndItemCount() {
        val text = """
            SUBTOTAL 605.09
            **** TOTAL 619.10
            Items Sold: 51
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(605.09, r.subtotal ?: -1.0, 0.0001)
        assertEquals(51, r.itemCount)
    }

    // Regression: a leading-minus amount ("-4.00") is a discount, not a dropped line. See Bug 2.
    @Test fun leadingMinusIsADiscount() {
        val text = """
            APPLES 5.00
            COUPON -4.00
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(listOf("APPLES"), r.items.map { it.name })
        assertEquals(4.00, r.discount, 0.0001)
    }

    @Test fun blankAndNoiseLinesIgnored() {
        val text = """

            Chicago (S. Loop) #1107
            RB Member 111945773512

            38742 SWEET CORN 4.99 E
        """.trimIndent()
        val r = ReceiptParser.parse(text)
        assertEquals(listOf("SWEET CORN"), r.items.map { it.name })
    }
}
