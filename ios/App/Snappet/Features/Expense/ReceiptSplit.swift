import Foundation

/// Pure, device-free math for splitting an itemized receipt across people.
///
/// Each `ReceiptItem` is shared equally among its `assignees`. Tax is then allocated to
/// each person in proportion to their pre-tax item subtotal, and the discount (instant
/// savings) is credited back the same way. Everything is reconciled to whole cents with a
/// largest-remainder pass so the per-person totals sum **exactly** to the receipt's grand
/// total — which is what keeps the settle-up balances penny-perfect. Kept free of
/// SwiftData / SwiftUI so it runs in `SnappetTests` with no simulator.
enum ReceiptSplit {

    /// One person's slice of the receipt. `total == itemsSubtotal + tax - discount`.
    struct PersonShare: Identifiable, Equatable {
        let name: String
        let itemsSubtotal: Double
        let tax: Double
        let discount: Double
        let total: Double
        var id: String { name }
    }

    /// The full breakdown: the headline figures plus each person's slice.
    struct Result: Equatable {
        let perPerson: [PersonShare]
        let itemsSubtotal: Double
        let tax: Double
        let discount: Double
        /// Items subtotal + tax − discount. The amount the payer actually paid.
        var grandTotal: Double { itemsSubtotal + tax - discount }
        /// Sum of the prices of items with no one assigned — not attributed to anyone.
        let unassignedSubtotal: Double
    }

    /// Compute the per-person breakdown for a receipt.
    ///
    /// - Parameters:
    ///   - items: the receipt lines; each is split equally among its `assignees`.
    ///   - taxAmount: total tax, allocated proportional to pre-tax item share.
    ///   - discountAmount: total discount/instant-savings, credited proportionally.
    ///   - order: preferred display order for people (e.g. the group's participants).
    ///     Anyone assigned to an item but missing from `order` is appended in first-seen
    ///     order. People in `order` with no items are omitted from `perPerson`.
    static func compute(items: [ReceiptItem],
                        taxAmount: Double = 0,
                        discountAmount: Double = 0,
                        order: [String] = []) -> Result {
        // Raw (un-rounded) pre-tax subtotal each person owes from their shared items.
        var rawSubtotal: [String: Double] = [:]
        var seen: [String] = []
        var unassigned = 0.0

        for item in items {
            let sharers = item.assignees
            guard !sharers.isEmpty else {
                unassigned += item.price
                continue
            }
            let share = item.price / Double(sharers.count)
            for person in sharers {
                if rawSubtotal[person] == nil { seen.append(person) }
                rawSubtotal[person, default: 0] += share
            }
        }

        // Stable display order: requested order first, then any extra assignees.
        var people = order.filter { rawSubtotal[$0] != nil }
        for person in seen where !people.contains(person) { people.append(person) }

        let subtotals = people.map { rawSubtotal[$0] ?? 0 }
        let subtotalTotal = subtotals.reduce(0, +)

        // Allocate tax & discount proportional to each person's pre-tax subtotal. With no
        // taxable base (everything unassigned), there is nothing to allocate.
        let taxRaw = proportional(subtotals, of: taxAmount, base: subtotalTotal)
        let discountRaw = proportional(subtotals, of: discountAmount, base: subtotalTotal)
        let totalRaw = people.indices.map { subtotals[$0] + taxRaw[$0] - discountRaw[$0] }

        // Reconcile each column to whole cents so every column sums to its target exactly.
        // (`reconcile` of an empty list returns empty, so a receipt with no assigned items
        // simply allocates nothing — there's no one to charge.)
        let tax = reconcile(taxRaw, target: roundCents(taxAmount))
        let discount = reconcile(discountRaw, target: roundCents(discountAmount))
        let grandTarget = roundCents(subtotalTotal) + sum(tax) - sum(discount)
        let totals = reconcile(totalRaw, target: grandTarget)

        // Derive the displayed subtotal from the reconciled columns so each row is
        // internally consistent: subtotal = total − tax + discount.
        let shares = people.indices.map { i in
            PersonShare(name: people[i],
                        itemsSubtotal: totals[i] - tax[i] + discount[i],
                        tax: tax[i],
                        discount: discount[i],
                        total: totals[i])
        }

        return Result(perPerson: shares,
                      itemsSubtotal: roundCents(subtotalTotal),
                      tax: sum(tax),
                      discount: sum(discount),
                      unassignedSubtotal: roundCents(unassigned))
    }

    // MARK: - Helpers

    /// Distribute `amount` across `weights` proportionally. Falls back to an equal split
    /// when the weight base is zero so a tax-only/discount-only edge case still allocates.
    private static func proportional(_ weights: [Double], of amount: Double, base: Double) -> [Double] {
        guard !weights.isEmpty, amount != 0 else { return weights.map { _ in 0 } }
        if base <= 0 {
            let each = amount / Double(weights.count)
            return weights.map { _ in each }
        }
        return weights.map { amount * ($0 / base) }
    }

    /// Round each raw amount to whole cents so the rounded values sum **exactly** to
    /// `target` (largest-remainder apportionment). Pennies of rounding error land on the
    /// people with the largest fractional remainders.
    private static func reconcile(_ raw: [Double], target: Double) -> [Double] {
        guard !raw.isEmpty else { return [] }
        let targetCents = Int((target * 100).rounded())
        var cents = raw.map { Int(($0 * 100).rounded(.down)) }
        var remaining = targetCents - cents.reduce(0, +)

        let fractions = raw.map { ($0 * 100) - ($0 * 100).rounded(.down) }
        // Hand out leftover pennies to the largest fractional parts; claw back from the
        // smallest if we overshot (target below the floored sum).
        let ascending = raw.indices.sorted { fractions[$0] < fractions[$1] }
        let descending = Array(ascending.reversed())

        var k = 0
        while remaining > 0 {
            cents[descending[k % descending.count]] += 1
            remaining -= 1; k += 1
        }
        k = 0
        while remaining < 0 {
            cents[ascending[k % ascending.count]] -= 1
            remaining += 1; k += 1
        }
        return cents.map { Double($0) / 100.0 }
    }

    private static func roundCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func sum(_ values: [Double]) -> Double {
        roundCents(values.reduce(0, +))
    }
}
