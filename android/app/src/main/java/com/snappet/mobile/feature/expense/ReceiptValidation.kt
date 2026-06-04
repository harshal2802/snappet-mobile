package com.snappet.mobile.feature.expense

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Pure, device-free validation for a scanned/entered receipt: cross-checks the captured items
 * against the totals printed on the receipt so a bad OCR read is surfaced rather than silently
 * producing a wrong split. Advisory only — the banner never blocks saving. Ported 1:1 from the
 * iOS `ReceiptValidation`.
 */
object ReceiptValidation {

    enum class Status { PASS, WARN, FAIL }

    data class Check(val id: String, val title: String, val status: Status, val detail: String)

    data class Report(val checks: List<Check>) {
        val overall: Status
            get() = when {
                checks.any { it.status == Status.FAIL } -> Status.FAIL
                checks.any { it.status == Status.WARN } -> Status.WARN
                else -> Status.PASS
            }

        val headline: String
            get() = when (overall) {
                Status.PASS -> "Balanced"
                Status.WARN -> "Needs review"
                Status.FAIL -> "Doesn't add up"
            }
    }

    fun validate(
        result: ReceiptSplit.Result,
        detectedSubtotal: Double?,
        detectedTax: Double?,
        detectedTotal: Double?,
        detectedItemCount: Int?,
        lineItemCount: Int,
    ): Report {
        val checks = mutableListOf<Check>()
        val epsilon = 0.011

        val rawItems = round2(result.itemsSubtotal + result.unassignedSubtotal)
        val computedTotal = round2(rawItems - result.discount + result.tax)

        // 1. Items − discount + tax should equal the receipt total.
        if (detectedTotal != null) {
            val diff = round2(computedTotal - detectedTotal)
            if (abs(diff) < epsilon) {
                checks.add(Check("total", "Items + tax − discount = total", Status.PASS,
                    "${money(computedTotal)} = ${money(detectedTotal)}"))
            } else {
                checks.add(Check("total", "Total doesn't match the receipt", Status.FAIL,
                    "Computed ${money(computedTotal)} vs receipt ${money(detectedTotal)} — off by ${money(abs(diff))}"))
            }
        } else {
            checks.add(Check("total", "No receipt total to verify against", Status.WARN,
                "Couldn't read a total — double-check the items."))
        }

        // 2. Items − discount should match the printed subtotal.
        if (detectedSubtotal != null) {
            val computedSubtotal = round2(rawItems - result.discount)
            val diff = round2(computedSubtotal - detectedSubtotal)
            if (abs(diff) < epsilon) {
                checks.add(Check("subtotal", "Subtotal matches the receipt", Status.PASS,
                    "${money(computedSubtotal)} = ${money(detectedSubtotal)}"))
            } else {
                checks.add(Check("subtotal", "Subtotal differs", Status.WARN,
                    "Items − discount ${money(computedSubtotal)} vs receipt ${money(detectedSubtotal)}"))
            }
        }

        // 3. Tax entered should match the tax read off the receipt.
        if (detectedTax != null) {
            val diff = round2(result.tax - detectedTax)
            if (abs(diff) >= epsilon) {
                checks.add(Check("tax", "Tax differs from the receipt", Status.WARN,
                    "Entered ${money(result.tax)} vs receipt ${money(detectedTax)}"))
            }
        }

        // 4. Item count (informational — quantities can make these legitimately differ).
        if (detectedItemCount != null) {
            if (detectedItemCount == lineItemCount) {
                checks.add(Check("count", "Item count", Status.PASS, "$lineItemCount of $detectedItemCount"))
            } else {
                checks.add(Check("count", "Item count differs", Status.WARN,
                    "$lineItemCount entered · receipt says $detectedItemCount (quantities may differ)"))
            }
        }

        // 5. Everything should be assigned to someone.
        if (result.unassignedSubtotal > 0.005) {
            checks.add(Check("unassigned", "Unassigned items", Status.WARN,
                "${money(result.unassignedSubtotal)} isn't assigned to anyone yet"))
        }

        // 6. A discount larger than someone's items would push them negative.
        if (result.perPerson.any { it.total < -0.005 }) {
            checks.add(Check("negative", "Negative share", Status.FAIL,
                "A discount exceeds someone's items — check the split."))
        }

        return Report(checks)
    }

    private fun round2(value: Double): Double = (value * 100).roundToInt() / 100.0
    // Currency strings come from the shared top-level [money] in CurrencyFormat.kt.
}
