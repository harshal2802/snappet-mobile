package com.snappet.mobile.feature.expense

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * JVM unit tests for the pure receipt-type classifier and profile-aware parsing. Mirrors the iOS
 * `ReceiptClassifierTests`.
 */
class ReceiptClassifierTest {

    @Test fun classifiesWarehouse() {
        val text = "COSTCO WHOLESALE\nRB Member 111\nINSTANT SAVINGS 17.50"
        assertEquals(ReceiptType.WAREHOUSE, ReceiptClassifier.classify(text))
    }

    @Test fun classifiesRestaurant() {
        val text = "Server: Dana  Table 12\nGuests 3\nGRATUITY 18.00"
        assertEquals(ReceiptType.RESTAURANT, ReceiptClassifier.classify(text))
    }

    @Test fun classifiesGas() {
        val text = "SHELL\nUNLEADED REGULAR\nGALLONS 12.345\nPRICE/GAL 3.499"
        assertEquals(ReceiptType.GAS, ReceiptClassifier.classify(text))
    }

    @Test fun fallsBackToGenericWhenNothingMatches() {
        assertEquals(ReceiptType.GENERIC, ReceiptClassifier.classify("WIDGET 5.00\nGADGET 6.00"))
    }

    @Test fun restaurantTipBecomesALineItem() {
        val text = """
            Server: Dana
            Table 12
            Burger 14.00
            Fries 6.00
            TIP 4.00
            TOTAL 24.00
        """.trimIndent()
        val r = ReceiptParser.parse(text, ReceiptType.RESTAURANT.profile)
        assertEquals(listOf("Burger", "Fries", "Tip"), r.items.map { it.name })
        assertEquals(4.00, r.items.last().price, 0.0001)
        assertEquals(24.00, r.total ?: -1.0, 0.0001)
    }

    @Test fun gasCollapsesToASingleFuelItem() {
        val text = """
            SHELL
            UNLEADED REGULAR
            GALLONS 12.345
            PRICE/GAL 3.499
            TOTAL 43.20
        """.trimIndent()
        val r = ReceiptParser.parse(text, ReceiptType.GAS.profile)
        assertEquals(listOf("Fuel"), r.items.map { it.name })
        assertEquals(43.20, r.items.first().price, 0.0001)
    }

    @Test fun genericProfileIsUnchangedDefault() {
        val r = ReceiptParser.parse("2015573 CHSEBRGRCAP 11.99 A")
        assertEquals(listOf("CHSEBRGRCAP"), r.items.map { it.name })
    }
}
