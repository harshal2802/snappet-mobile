import Foundation
import SwiftData

/// One journal entry in the shared store. The integrator appends this type to
/// `SnappetSchema.models`.
///
/// Note: `body` is a stored `String` here, not the SwiftUI `View.body` — this is a
/// `@Model` class, not a `View`, so the name does not clash.
@Model
final class JournalEntry {
    /// Optional user-provided title. May be empty.
    var title: String
    /// The entry's free-form text.
    var body: String
    /// When the entry was first created.
    var createdAt: Date
    /// When the entry was last edited (equals `createdAt` until first edit).
    var updatedAt: Date

    init(title: String, body: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
