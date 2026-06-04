package com.snappet.mobile.feature.expense

import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Pure, device-free math for splitting an itemized receipt across people. Ported 1:1 from the
 * iOS `ReceiptSplit`: each [ReceiptItem] is shared equally among its assignees; tax is allocated
 * proportional to each person's pre-tax subtotal; the discount is credited back the same way; and
 * every column is reconciled to whole cents (largest-remainder) so the per-person totals sum
 * **exactly** to the grand total — which keeps the settle-up balances penny-perfect. Kept free of
 * Room/Compose so it runs in plain JVM unit tests.
 */
object ReceiptSplit {

    /** One person's slice. `total == itemsSubtotal + tax - discount`. */
    data class PersonShare(
        val name: String,
        val itemsSubtotal: Double,
        val tax: Double,
        val discount: Double,
        val total: Double,
    )

    /** The full breakdown: the headline figures plus each person's slice. */
    data class Result(
        val perPerson: List<PersonShare>,
        val itemsSubtotal: Double,
        val tax: Double,
        val discount: Double,
        /** Sum of the prices of items with no one assigned — not attributed to anyone. */
        val unassignedSubtotal: Double,
    ) {
        /** Items subtotal + tax − discount. The amount the payer actually paid. */
        val grandTotal: Double get() = itemsSubtotal + tax - discount
    }

    /**
     * Compute the per-person breakdown. [order] is the preferred display order (e.g. the group's
     * participants); anyone assigned but missing from it is appended in first-seen order, and people
     * in [order] with no items are omitted.
     */
    fun compute(
        items: List<ReceiptItem>,
        taxAmount: Double = 0.0,
        discountAmount: Double = 0.0,
        order: List<String> = emptyList(),
    ): Result {
        val rawSubtotal = LinkedHashMap<String, Double>()
        val seen = mutableListOf<String>()
        var unassigned = 0.0

        for (item in items) {
            val sharers = item.assignees
            if (sharers.isEmpty()) {
                unassigned += item.price
                continue
            }
            val share = item.price / sharers.size
            for (person in sharers) {
                if (!rawSubtotal.containsKey(person)) seen.add(person)
                rawSubtotal[person] = (rawSubtotal[person] ?: 0.0) + share
            }
        }

        val people = mutableListOf<String>()
        order.forEach { if (rawSubtotal.containsKey(it)) people.add(it) }
        seen.forEach { if (!people.contains(it)) people.add(it) }

        val subtotals = people.map { rawSubtotal[it] ?: 0.0 }
        val subtotalTotal = subtotals.sum()

        val taxRaw = proportional(subtotals, taxAmount, subtotalTotal)
        val discountRaw = proportional(subtotals, discountAmount, subtotalTotal)
        val totalRaw = people.indices.map { subtotals[it] + taxRaw[it] - discountRaw[it] }

        val tax = reconcile(taxRaw, roundCents(taxAmount))
        val discount = reconcile(discountRaw, roundCents(discountAmount))
        val grandTarget = roundCents(subtotalTotal) + sum(tax) - sum(discount)
        val totals = reconcile(totalRaw, grandTarget)

        val shares = people.indices.map { i ->
            PersonShare(
                name = people[i],
                itemsSubtotal = totals[i] - tax[i] + discount[i],
                tax = tax[i],
                discount = discount[i],
                total = totals[i],
            )
        }

        return Result(
            perPerson = shares,
            itemsSubtotal = roundCents(subtotalTotal),
            tax = sum(tax),
            discount = sum(discount),
            unassignedSubtotal = roundCents(unassigned),
        )
    }

    /** Distribute [amount] across [weights] proportionally; equal-split when the base is zero. */
    private fun proportional(weights: List<Double>, amount: Double, base: Double): List<Double> {
        if (weights.isEmpty() || amount == 0.0) return weights.map { 0.0 }
        if (base <= 0.0) {
            val each = amount / weights.size
            return weights.map { each }
        }
        return weights.map { amount * (it / base) }
    }

    /** Round each raw amount to whole cents so the rounded values sum exactly to [target]. */
    private fun reconcile(raw: List<Double>, target: Double): List<Double> {
        if (raw.isEmpty()) return emptyList()
        val targetCents = (target * 100).roundToInt()
        val cents = raw.map { floor(it * 100).toInt() }.toMutableList()
        var remaining = targetCents - cents.sum()

        val fractions = raw.map { (it * 100) - floor(it * 100) }
        val ascending = raw.indices.sortedBy { fractions[it] }
        val descending = ascending.reversed()

        var k = 0
        while (remaining > 0) {
            cents[descending[k % descending.size]] += 1
            remaining -= 1; k += 1
        }
        k = 0
        while (remaining < 0) {
            cents[ascending[k % ascending.size]] -= 1
            remaining += 1; k += 1
        }
        return cents.map { it / 100.0 }
    }

    private fun roundCents(value: Double): Double = (value * 100).roundToInt() / 100.0

    private fun sum(values: List<Double>): Double = roundCents(values.sum())
}
