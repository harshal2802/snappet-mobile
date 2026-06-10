package com.snappet.mobile.feature.expense

/**
 * Pure value types + the balance / settle-up math for one group. Kept free of Room and Compose
 * so it is trivial to read and reason about. Ported 1:1 from the iOS `SettleUp` enum.
 */
object SettleUp {

    /**
     * Participant-name suggestions for the group sheet: every name used across groups
     * (first-seen order, deduped case-insensitively, trimmed). Pure → unit-tested.
     * Mirrors iOS `SettleUp.participantSuggestions` (issue #88).
     */
    fun participantSuggestions(existingGroups: List<List<String>>): List<String> {
        val seen = HashSet<String>()
        val result = ArrayList<String>()
        for (group in existingGroups) {
            for (raw in group) {
                val trimmed = raw.trim()
                if (trimmed.isEmpty() || !seen.add(trimmed.lowercase())) continue
                result.add(trimmed)
            }
        }
        return result
    }

    /** A participant's net position: `paid - owed`. Positive => owed to them; negative => they owe. */
    data class Balance(val name: String, val net: Double)

    /** One leg of the suggested settlement: [debtor] pays [creditor] [amount]. */
    data class Transfer(val debtor: String, val creditor: String, val amount: Double)

    /**
     * Net balance per participant across all expenses. For each (non-settlement) expense the cost
     * is split equally among its participants and the payer is credited the full amount. A
     * settlement record is not split: the payer's net rises by `amount` and the recipient's falls
     * by `amount`, so an outstanding debtor/creditor pair converges to zero once a settlement equal
     * to the suggested transfer is recorded. Preserves the group's participant order.
     */
    fun balances(participants: List<String>, expenses: List<ExpenseRecord>): List<Balance> {
        val net = LinkedHashMap<String, Double>()
        participants.forEach { net[it] = 0.0 }

        for (expense in expenses) {
            if (expense.isReceipt) {
                // Itemized: credit the payer the grand total, debit each person their slice.
                // Credit the *recomputed* grand total (not the stored `amount`) so the receipt
                // always nets to zero — the per-person totals sum exactly to it by construction,
                // whereas a denormalized `amount` could drift from the items it's derived from.
                val result = ReceiptSplit.compute(
                    expense.items, expense.taxAmount, expense.discountAmount, participants,
                )
                net[expense.payer] = (net[expense.payer] ?: 0.0) + result.grandTotal
                for (share in result.perPerson) {
                    net[share.name] = (net[share.name] ?: 0.0) - share.total
                }
                continue
            }

            val splitters = expense.participants
            // Guard against an expense with no split targets (shouldn't happen via the UI).
            if (splitters.isEmpty()) continue

            if (expense.isSettlement) {
                // Direct transfer: payer pays the single recipient `amount`.
                val recipient = splitters[0]
                net[expense.payer] = (net[expense.payer] ?: 0.0) + expense.amount
                net[recipient] = (net[recipient] ?: 0.0) - expense.amount
                continue
            }

            val share = expense.amount / splitters.size

            // Credit the payer for what they fronted.
            net[expense.payer] = (net[expense.payer] ?: 0.0) + expense.amount
            // Debit each splitter their equal share.
            for (person in splitters) {
                net[person] = (net[person] ?: 0.0) - share
            }
        }

        // Preserve the group's participant order for a stable UI.
        return participants.map { Balance(it, net[it] ?: 0.0) }
    }

    /**
     * Greedy settle-up: repeatedly match the largest debtor against the largest creditor, transfer
     * the smaller of the two magnitudes, and continue until all balances are (near) zero.
     */
    fun transfers(balances: List<Balance>): List<Transfer> {
        val epsilon = 0.005 // sub-cent noise from equal-split division
        val debtors = balances.filter { it.net < -epsilon }
            .map { MutableEntry(it.name, -it.net) }
            .sortedByDescending { it.amount }
            .toMutableList()
        val creditors = balances.filter { it.net > epsilon }
            .map { MutableEntry(it.name, it.net) }
            .sortedByDescending { it.amount }
            .toMutableList()

        val result = mutableListOf<Transfer>()
        var i = 0
        var j = 0
        while (i < debtors.size && j < creditors.size) {
            val pay = minOf(debtors[i].amount, creditors[j].amount)
            result.add(Transfer(debtors[i].name, creditors[j].name, pay))
            debtors[i].amount -= pay
            creditors[j].amount -= pay
            if (debtors[i].amount <= epsilon) i += 1
            if (creditors[j].amount <= epsilon) j += 1
        }
        return result
    }

    private data class MutableEntry(val name: String, var amount: Double)
}
