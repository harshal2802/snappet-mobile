import Foundation

/// Pure, device-free validation for a scanned/entered receipt: it cross-checks the items the
/// user captured against the totals printed on the receipt, so a bad OCR read (a dropped item,
/// a mis-read tax line) is surfaced instead of silently producing a wrong split.
///
/// It is advisory — `Report` is rendered as a banner that the user can expand; it never blocks
/// saving. Kept free of SwiftUI/SwiftData so it runs in `SnappetTests` with no simulator.
enum ReceiptValidation {

    enum Status: Equatable { case pass, warn, fail }

    /// One independent check (e.g. "items + tax − discount = total").
    struct Check: Identifiable, Equatable {
        let id: String
        let title: String
        let status: Status
        let detail: String
    }

    struct Report: Equatable {
        let checks: [Check]

        /// The worst status across all checks drives the banner colour/headline.
        var overall: Status {
            if checks.contains(where: { $0.status == .fail }) { return .fail }
            if checks.contains(where: { $0.status == .warn }) { return .warn }
            return .pass
        }

        var headline: String {
            switch overall {
            case .pass: return "Balanced"
            case .warn: return "Needs review"
            case .fail: return "Doesn't add up"
            }
        }
    }

    /// Build the report from the computed split (`result`) and what the parser read off the
    /// receipt. All comparisons round to the cent; differences under 1¢ count as equal.
    ///
    /// - Parameters:
    ///   - result: the per-person split (carries assigned subtotal, tax, discount, unassigned).
    ///   - detectedSubtotal/detectedTax/detectedTotal/detectedItemCount: values read by
    ///     `ReceiptParser` (any may be nil when the receipt didn't print them or wasn't scanned).
    ///   - lineItemCount: how many line items the user actually has (price > 0).
    static func validate(result: ReceiptSplit.Result,
                         detectedSubtotal: Double?,
                         detectedTax: Double?,
                         detectedTotal: Double?,
                         detectedItemCount: Int?,
                         lineItemCount: Int) -> Report {
        var checks: [Check] = []
        let epsilon = 0.011

        // The full item value includes items not yet assigned to anyone.
        let rawItems = round2(result.itemsSubtotal + result.unassignedSubtotal)
        let computedTotal = round2(rawItems - result.discount + result.tax)

        // 1. The headline check: items − discount + tax should equal the receipt total.
        if let total = detectedTotal {
            let diff = round2(computedTotal - total)
            if abs(diff) < epsilon {
                checks.append(Check(id: "total", title: "Items + tax − discount = total",
                                    status: .pass, detail: "\(money(computedTotal)) = \(money(total))"))
            } else {
                checks.append(Check(id: "total", title: "Total doesn’t match the receipt",
                                    status: .fail,
                                    detail: "Computed \(money(computedTotal)) vs receipt \(money(total)) — off by \(money(abs(diff)))"))
            }
        } else {
            checks.append(Check(id: "total", title: "No receipt total to verify against",
                                status: .warn, detail: "Couldn’t read a total — double-check the items."))
        }

        // 2. Items − discount should match the printed subtotal.
        if let subtotal = detectedSubtotal {
            let computedSubtotal = round2(rawItems - result.discount)
            let diff = round2(computedSubtotal - subtotal)
            if abs(diff) < epsilon {
                checks.append(Check(id: "subtotal", title: "Subtotal matches the receipt",
                                    status: .pass, detail: "\(money(computedSubtotal)) = \(money(subtotal))"))
            } else {
                checks.append(Check(id: "subtotal", title: "Subtotal differs",
                                    status: .warn,
                                    detail: "Items − discount \(money(computedSubtotal)) vs receipt \(money(subtotal))"))
            }
        }

        // 3. The tax entered should match the tax read off the receipt.
        if let detectedTax {
            let diff = round2(result.tax - detectedTax)
            if abs(diff) >= epsilon {
                checks.append(Check(id: "tax", title: "Tax differs from the receipt",
                                    status: .warn,
                                    detail: "Entered \(money(result.tax)) vs receipt \(money(detectedTax))"))
            }
        }

        // 4. Item count (informational — quantities can make these legitimately differ).
        if let count = detectedItemCount {
            if count == lineItemCount {
                checks.append(Check(id: "count", title: "Item count", status: .pass,
                                    detail: "\(lineItemCount) of \(count)"))
            } else {
                checks.append(Check(id: "count", title: "Item count differs", status: .warn,
                                    detail: "\(lineItemCount) entered · receipt says \(count) (quantities may differ)"))
            }
        }

        // 5. Everything should be assigned to someone.
        if result.unassignedSubtotal > 0.005 {
            checks.append(Check(id: "unassigned", title: "Unassigned items", status: .warn,
                                detail: "\(money(result.unassignedSubtotal)) isn’t assigned to anyone yet"))
        }

        // 6. A discount larger than someone's items would push them negative.
        if result.perPerson.contains(where: { $0.total < -0.005 }) {
            checks.append(Check(id: "negative", title: "Negative share", status: .fail,
                                detail: "A discount exceeds someone’s items — check the split."))
        }

        return Report(checks: checks)
    }

    // MARK: - Helpers

    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }
}
