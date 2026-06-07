package com.snappet.mobile.feature.expense

/**
 * Shared currency formatter for the Expense feature — one definition so the receipt summary,
 * detail, validation banner and expense rows all render amounts identically. Mirrors the iOS
 * `currency(_:)` helper. (See [formatAmount] for the symbol-less edit-field variant.)
 */
fun money(value: Double): String = "$" + String.format("%.2f", value)
