import Foundation
import SwiftData

/// A group of people who share expenses (e.g. "Trip", "Roommates"). Keyed by a stable
/// `id` (UUID) so `ExpenseRecord` rows can reference it independently of SwiftData
/// object identity. The integrator appends this type to `SnappetSchema.models`.
@Model
final class ExpenseGroup {
    /// Stable identity used to key `ExpenseRecord` rows via `groupID`.
    var id: UUID
    var name: String
    /// Participant display names. SwiftData stores `[String]` natively.
    var participants: [String]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, participants: [String], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.participants = participants
        self.createdAt = createdAt
    }
}

/// A single expense within a group. We reference the owning group by `groupID`
/// (matching `ExpenseGroup.id`) rather than a SwiftData relationship — this keeps the
/// model flat and the settle-up math easy to fetch per group via a predicate.
@Model
final class ExpenseRecord {
    /// Matches `ExpenseGroup.id`.
    var groupID: UUID
    var title: String
    var amount: Double
    /// The single participant who paid the bill.
    var payer: String
    /// Participants the cost is split equally among (defaults to all group members).
    var participants: [String]
    var date: Date

    init(groupID: UUID, title: String, amount: Double, payer: String,
         participants: [String], date: Date = .now) {
        self.groupID = groupID
        self.title = title
        self.amount = amount
        self.payer = payer
        self.participants = participants
        self.date = date
    }
}
