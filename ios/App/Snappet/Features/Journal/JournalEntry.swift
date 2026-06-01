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
    /// Free-form tags for organizing/filtering. Stored normalized (see `normalizeTags`):
    /// trimmed, lowercased, de-duplicated, empties dropped. Defaulted so SwiftData performs a
    /// lightweight additive migration for stores created before this property existed.
    var tags: [String] = []

    init(title: String, body: String, createdAt: Date = .now, updatedAt: Date = .now, tags: [String] = []) {
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = JournalEntry.normalizeTags(tags)
    }

    /// Normalize raw tag strings: trim whitespace, lowercase, drop empties, and de-duplicate
    /// while preserving first-seen order.
    static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
