import Foundation
import SwiftData

/// Your choices about one Library activity (Library redesign L3, prompt 185): pinned to the top, or hidden from the
/// Library — and (L4a, prompt 186) an activity you CREATED before ever logging it ("a climb to project", "a run
/// route"): its `template` is the entry "Log it now" starts from. Everything else is derived from history.
/// Keyed by the activity's `ActivityKey` (as `exerciseId` + U+001F + `nameKey`), so a rename or merge moves the row.
/// In the suite backup (`SnappetBackup.LibraryEntryRow`).
@Model
final class LibraryEntry {
    var id: UUID
    var activityKeyRaw: String
    var isPinned: Bool
    var isHidden: Bool
    var updatedAt: Date
    /// A created activity's template (`LibraryTemplate`, JSON); `nil` for a pin/hide-only entry. Additive optional
    /// (prompt 186) → lightweight migration; older backups decode without it.
    var templateData: Data?
    /// When the activity was created in the Library (prompt 186); `nil` for pin/hide-only entries.
    var createdAt: Date?

    init(id: UUID = UUID(), key: ActivityKey, isPinned: Bool = false, isHidden: Bool = false, updatedAt: Date = .now) {
        self.id = id
        self.activityKeyRaw = LibraryEntry.raw(key)
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.updatedAt = updatedAt
    }

    var key: ActivityKey? { LibraryEntry.key(activityKeyRaw) }

    var template: LibraryTemplate? {
        get { templateData.flatMap { try? JSONDecoder().decode(LibraryTemplate.self, from: $0) } }
        set { templateData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

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

/// What a created-but-never-logged activity is (prompt 186): the session entity to log (no sets) and, for a run
/// route, its distance.
struct LibraryTemplate: Codable, Equatable, Sendable {
    var exercise: SessionExercise
    var targetDistanceMeters: Double?
}
