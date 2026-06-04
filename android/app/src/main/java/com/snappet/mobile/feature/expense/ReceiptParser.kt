package com.snappet.mobile.feature.expense

/**
 * Pure, device-free parser that turns pasted / OCR'd receipt text into line items plus the
 * detected tax, discount and total. Ported 1:1 from the iOS `ReceiptParser`. Heuristic but
 * unit-tested against real Costco lines: a row ending in a money amount is an item (leading
 * item-codes and a trailing tax-flag letter are stripped); a trailing-minus amount is an
 * instant-savings/discount; SUBTOTAL / TAX / TOTAL / payment rows are not items.
 */
object ReceiptParser {

    data class ParsedReceipt(
        val items: List<ReceiptItem>,
        val discount: Double,
        val tax: Double?,
        val total: Double?,
    )

    private val skipKeywords = listOf(
        "SUBTOTAL", "TOTAL", "TAX", "CHANGE", "BALANCE", "VISA", "MASTERCARD",
        "DEBIT", "CREDIT", "AMOUNT", "INSTANT SAVINGS", "MEMBER", "CHIP READ",
        "APPROVED", "RESP", "TRAN", "AID", "SEQ", "APP#", "ITEMS SOLD", "FSA",
        "COUNT", "BOTTOM OF BASKET", "THANK YOU", "PLEASE COME", "OP#", "WHSE",
        "TRM", "TRN", "WHOLESALE", "PURCHASE", "ITEM",
    )

    fun parse(text: String): ParsedReceipt {
        val items = mutableListOf<ReceiptItem>()
        var discount = 0.0
        var tax: Double? = null
        var total: Double? = null

        for (rawLine in text.split('\n', '\r')) {
            val line = rawLine.trim()
            if (line.isEmpty()) continue
            val upper = line.uppercase()

            val money = lastMoney(line) ?: continue

            // Discount / instant-savings rows (trailing minus) — credit, don't itemize.
            if (money.isNegative) {
                discount += money.value
                continue
            }

            // Summary / metadata rows: capture tax & grand total, never itemize.
            if (skipKeywords.any { upper.contains(it) }) {
                if (upper.contains("TAX") && !upper.contains("N/TAX")) {
                    tax = money.value
                } else if (upper.contains("TOTAL") &&
                    !upper.contains("SUBTOTAL") &&
                    !upper.contains("NUMBER") &&
                    !upper.contains("BOB")
                ) {
                    total = maxOf(total ?: 0.0, money.value)
                }
                continue
            }

            val name = cleanName(line, money.token)
            if (name.isEmpty()) continue
            items.add(ReceiptItem(name, money.value))
        }

        return ParsedReceipt(items, discount, tax, total)
    }

    private data class Money(val value: Double, val isNegative: Boolean, val token: String)

    private fun lastMoney(line: String): Money? {
        var found: Money? = null
        for (token in line.split(' ', '\t').filter { it.isNotEmpty() }) {
            money(token)?.let { found = it }
        }
        return found
    }

    private fun money(token: String): Money? {
        var t = token
        // Drop a trailing single tax-flag letter (Costco: "28.99E", "4.00-A").
        if (t.length > 1 && t.last().isLetter()) t = t.dropLast(1)
        val isNegative = t.endsWith("-")
        if (isNegative) t = t.dropLast(1)
        t = t.replace("$", "").replace(",", "")

        val dot = t.indexOf('.')
        if (dot < 0) return null
        if (t.length - dot != 3) return null // require exactly two decimals
        val intPart = t.substring(0, dot)
        val decPart = t.substring(dot + 1)
        if (intPart.isEmpty() || !intPart.all { it.isDigit() } || !decPart.all { it.isDigit() }) return null
        val value = t.toDoubleOrNull() ?: return null
        return Money(value, isNegative, token)
    }

    private fun cleanName(line: String, priceToken: String): String {
        val idx = line.indexOf(priceToken)
        val head = if (idx >= 0) line.substring(0, idx) else line
        val tokens = head.split(' ', '\t').filter { it.isNotEmpty() }.toMutableList()
        // Leading single-letter tax flag (Costco prefixes some rows with E/F).
        if (tokens.isNotEmpty() && tokens[0].length == 1 && tokens[0].all { it.isLetter() }) {
            tokens.removeAt(0)
        }
        // Leading bare item-codes (pure digits, possibly with a stray '/').
        while (tokens.isNotEmpty() && tokens[0].all { it.isDigit() || it == '/' } && tokens[0].any { it.isDigit() }) {
            tokens.removeAt(0)
        }
        return tokens.joinToString(" ").trim()
    }
}
