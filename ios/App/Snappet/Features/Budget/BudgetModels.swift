import Foundation
import SwiftData

/// A spending category with a monthly limit (e.g. "Groceries", $400). Keyed by a stable
/// `id` (UUID) so transactions reference it independently of SwiftData object identity.
@Model
final class BudgetCategory {
    /// Stable identity used to key `BudgetTransaction` records.
    var id: UUID
    var name: String
    /// The budgeted spend ceiling for one calendar month.
    var monthlyLimit: Double
    var createdAt: Date

    init(id: UUID = UUID(), name: String, monthlyLimit: Double, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.monthlyLimit = monthlyLimit
        self.createdAt = createdAt
    }
}

/// A single spend logged against a category. `categoryID` matches `BudgetCategory.id`
/// so categories can be deleted/recreated without dangling object references.
@Model
final class BudgetTransaction {
    /// Matches `BudgetCategory.id`.
    var categoryID: UUID
    var amount: Double
    var note: String
    var date: Date

    init(categoryID: UUID, amount: Double, note: String = "", date: Date = .now) {
        self.categoryID = categoryID
        self.amount = amount
        self.note = note
        self.date = date
    }
}
