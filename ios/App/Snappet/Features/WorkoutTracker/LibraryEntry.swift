import Foundation
import SwiftData

/// Your choices about one Library activity (Library redesign L3, prompt 185): pinned to the top, or hidden from the
/// Library. Everything else about an activity is derived from history; this is the only thing the Library stores.
/// Keyed by the activity's `ActivityKey` (as `exerciseId` + U+001F + `nameKey`), so a rename or merge moves the row.
/// In the suite backup (`SnappetBackup.LibraryEntryRow`).
@Model
final class LibraryEntry {
    var id: UUID
    var activityKeyRaw: String
    var isPinned: Bool
    var isHidden: Bool
    var updatedAt: Date

    init(id: UUID = UUID(), key: ActivityKey, isPinned: Bool = false, isHidden: Bool = false, updatedAt: Date = .now) {
        self.id = id
        self.activityKeyRaw = LibraryEntry.raw(key)
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.updatedAt = updatedAt
    }

    var key: ActivityKey? { LibraryEntry.key(activityKeyRaw) }

    static func raw(_ key: ActivityKey) -> String { key.exerciseId + "\u{1f}" + key.nameKey }

    static func key(_ raw: String) -> ActivityKey? {
        let parts = raw.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return ActivityKey(exerciseId: parts[0], nameKey: parts[1])
    }

    // MARK: - Edge helpers (the views call these; the rules are LibraryMaintenance's)

    /// The entry for `key`, created when `create` and missing.
    @MainActor
    static func entry(for key: ActivityKey, in context: ModelContext, create: Bool) -> LibraryEntry? {
        let raw = raw(key)
        let found = try? context.fetch(FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.activityKeyRaw == raw })).first
        if let found { return found }
        guard create else { return nil }
        let new = LibraryEntry(key: key)
        context.insert(new)
        return new
    }
}
