import Foundation
import SwiftData

/// A single committed tip calculation, persisted so the Tip mini-app can show a
/// history of past splits (its first persisted model — see `decisions.md`). The
/// integrator appends `TipCalculation.self` to `SnappetSchema.models`.
///
/// Stored flat (no relationships): each row is a self-contained snapshot of the
/// inputs (`bill`, `tipPct`, `people`) and the derived outputs (`tipAmount`,
/// `total`) at the moment the bill committed, keyed for display by `date`.
@Model
final class TipCalculation {
    /// The raw bill amount the tip was computed on.
    var bill: Double
    /// Effective tip percentage applied (may be fractional when round-up adjusts it).
    var tipPct: Double
    /// Number of people the total was split between.
    var people: Int
    /// Tip portion in the bill's currency.
    var tipAmount: Double
    /// Grand total (bill + tip), after any round-up.
    var total: Double
    /// When the calculation was committed (used for newest-first sorting & display).
    var date: Date

    init(bill: Double, tipPct: Double, people: Int,
         tipAmount: Double, total: Double, date: Date = .now) {
        self.bill = bill
        self.tipPct = tipPct
        self.people = people
        self.tipAmount = tipAmount
        self.total = total
        self.date = date
    }
}
