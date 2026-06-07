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

/// A single line item on an itemized receipt: a name, its price, and the participants
/// who share it equally. Pure `Codable` value type so the split math stays testable and
/// SwiftData can persist `[ReceiptItem]` as a composite attribute on `ExpenseRecord`.
struct ReceiptItem: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var price: Double
    /// Participants splitting this item equally. Empty means "unassigned" — its cost is
    /// not attributed to anyone until someone is picked.
    var assignees: [String]

    init(id: UUID = UUID(), name: String, price: Double, assignees: [String] = []) {
        self.id = id
        self.name = name
        self.price = price
        self.assignees = assignees
    }
}

/// A single expense within a group. We reference the owning group by `groupID`
/// (matching `ExpenseGroup.id`) rather than a SwiftData relationship — this keeps the
/// model flat and the settle-up math easy to fetch per group via a predicate.
///
/// Two shapes share this one model:
///  - **Even split** (`items` empty): `amount` is split equally among `participants`.
///  - **Itemized receipt** (`items` non-empty): each `ReceiptItem` is split among its own
///    `assignees`, then `taxAmount` is allocated proportionally and `discountAmount`
///    proportionally credited back (see `ReceiptSplit`). `amount` is the grand total the
///    `payer` actually paid (items subtotal + tax − discount).
@Model
final class ExpenseRecord {
    /// Matches `ExpenseGroup.id`.
    var groupID: UUID
    var title: String
    var amount: Double
    /// The single participant who paid the bill.
    var payer: String
    /// Participants the cost is split equally among (defaults to all group members).
    /// For an itemized receipt this is the set of everyone who shares at least one item.
    var participants: [String]
    var date: Date
    /// When `true`, this record is a manual settlement ("`payer` paid the single
    /// participant `amount` back") rather than a shared expense. It feeds the balance
    /// math as a direct transfer: it is not split, and moves the pair toward zero.
    /// Additive with a default so the SwiftData migration stays lightweight.
    var isSettlement: Bool = false

    /// Itemized receipt lines. Empty for an even-split expense. When non-empty the
    /// balance math splits per item (each among its own assignees) rather than equally.
    /// Additive with a default so the SwiftData migration stays lightweight.
    var items: [ReceiptItem] = []
    /// Tax for an itemized receipt, allocated to people proportional to their pre-tax
    /// item share. Ignored when `items` is empty.
    var taxAmount: Double = 0
    /// Discount / instant-savings for an itemized receipt, credited proportional to each
    /// person's pre-discount item share. Ignored when `items` is empty.
    var discountAmount: Double = 0

    /// An itemized receipt rather than an even split.
    var isReceipt: Bool { !items.isEmpty }

    init(groupID: UUID, title: String, amount: Double, payer: String,
         participants: [String], date: Date = .now, isSettlement: Bool = false,
         items: [ReceiptItem] = [], taxAmount: Double = 0, discountAmount: Double = 0) {
        self.groupID = groupID
        self.title = title
        self.amount = amount
        self.payer = payer
        self.participants = participants
        self.date = date
        self.isSettlement = isSettlement
        self.items = items
        self.taxAmount = taxAmount
        self.discountAmount = discountAmount
    }
}
