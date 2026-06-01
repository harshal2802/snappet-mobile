import Foundation

/// Pure value types + the balance / settle-up math for one group. Kept free of
/// SwiftData and SwiftUI so it is trivial to read and reason about.
enum SettleUp {

    /// A participant's net position: `paid - owed`.
    /// Positive => the group owes them; negative => they owe the group.
    struct Balance: Identifiable {
        let name: String
        let net: Double
        var id: String { name }
    }

    /// One leg of the suggested settlement: `debtor` pays `creditor` `amount`.
    struct Transfer: Identifiable {
        let debtor: String
        let creditor: String
        let amount: Double
        let id = UUID()
    }

    /// Net balance per participant across all expenses.
    ///
    /// For each expense the cost is split equally among its `participants`; the `payer`
    /// is credited the full amount. A participant's net is therefore
    /// `(sum of amounts they paid) - (sum of their equal shares)`.
    ///
    /// A settlement record (`isSettlement == true`) is *not* split: it is a direct
    /// transfer where the `payer` pays the single recipient (its lone `participant`)
    /// `amount`. The payer's net rises by `amount` (they've now paid off that much) and
    /// the recipient's net falls by `amount` (they've been paid back), so an outstanding
    /// debtor/creditor pair converges to zero once a settlement equal to the suggested
    /// transfer is recorded.
    static func balances(participants: [String], expenses: [ExpenseRecord]) -> [Balance] {
        var net: [String: Double] = Dictionary(uniqueKeysWithValues: participants.map { ($0, 0.0) })

        for expense in expenses {
            // Guard against an expense with no split targets (shouldn't happen via the UI).
            guard !expense.participants.isEmpty else { continue }

            if expense.isSettlement {
                // Direct transfer: payer pays the single recipient `amount`.
                let recipient = expense.participants[0]
                net[expense.payer, default: 0] += expense.amount
                net[recipient, default: 0] -= expense.amount
                continue
            }

            let share = expense.amount / Double(expense.participants.count)

            // Credit the payer for what they fronted.
            net[expense.payer, default: 0] += expense.amount
            // Debit each splitter their equal share.
            for person in expense.participants {
                net[person, default: 0] -= share
            }
        }

        // Preserve the group's participant order for a stable UI.
        return participants.map { Balance(name: $0, net: net[$0] ?? 0) }
    }

    /// Greedy settle-up: repeatedly match the largest debtor against the largest
    /// creditor, transfer the smaller of the two magnitudes, and continue until all
    /// balances are (near) zero. This minimises the number of transfers in practice
    /// without guaranteeing the theoretical optimum — which is fine for this use case.
    static func transfers(from balances: [Balance]) -> [Transfer] {
        let epsilon = 0.005 // sub-cent noise from equal-split division
        var debtors = balances.filter { $0.net < -epsilon }
            .map { (name: $0.name, amount: -$0.net) }
            .sorted { $0.amount > $1.amount }
        var creditors = balances.filter { $0.net > epsilon }
            .map { (name: $0.name, amount: $0.net) }
            .sorted { $0.amount > $1.amount }

        var result: [Transfer] = []
        var i = 0
        var j = 0
        while i < debtors.count && j < creditors.count {
            let pay = min(debtors[i].amount, creditors[j].amount)
            result.append(Transfer(debtor: debtors[i].name,
                                    creditor: creditors[j].name,
                                    amount: pay))
            debtors[i].amount -= pay
            creditors[j].amount -= pay
            if debtors[i].amount <= epsilon { i += 1 }
            if creditors[j].amount <= epsilon { j += 1 }
        }
        return result
    }
}
