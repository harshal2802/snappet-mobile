import Foundation
import SwiftData

// MARK: - Clips overlay style — persistence (prompt 163)
//
// The user's default HR tile + title (`ClipOverlayStyle`) as ONE SwiftData row, so it rides the backup
// envelope (user's call: backed up, like favorites in prompt 162). The style is a JSON blob — the shape
// can grow (forward-compatible decode) without a schema migration. Newest row wins if a restore ever
// carries two.

@Model
final class ClipOverlayDefaults {
    var id: UUID
    /// JSON-encoded `ClipOverlayStyle`.
    var styleData: Data
    var updatedAt: Date

    init(id: UUID = UUID(), styleData: Data, updatedAt: Date = .now) {
        self.id = id
        self.styleData = styleData
        self.updatedAt = updatedAt
    }

    /// The saved default, or the built-in look when none is saved (or the blob won't decode).
    @MainActor
    static func style(in context: ModelContext) -> ClipOverlayStyle {
        var d = FetchDescriptor<ClipOverlayDefaults>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = 1
        guard let row = (try? context.fetch(d))?.first,
              let style = try? JSONDecoder().decode(ClipOverlayStyle.self, from: row.styleData) else { return .builtIn }
        return style
    }
}

/// The feed's handle on the saved style: a cached value the posters read, written by the ✎ sheet.
@Observable @MainActor final class ClipOverlayStyleStore {
    private(set) var style: ClipOverlayStyle = .builtIn
    private var context: ModelContext?

    /// Bind + (re)load — called on every feed rebuild, so a backup restore shows up.
    func attach(_ context: ModelContext) {
        self.context = context
        let loaded = ClipOverlayDefaults.style(in: context)
        if loaded != style { style = loaded }
    }

    /// Save `style` as the default (one row: update in place, drop any extras).
    func save(_ new: ClipOverlayStyle) {
        guard let context, let data = try? JSONEncoder().encode(new) else { return }
        let rows = (try? context.fetch(FetchDescriptor<ClipOverlayDefaults>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        if let keep = rows.first {
            keep.styleData = data
            keep.updatedAt = .now
            for extra in rows.dropFirst() { context.delete(extra) }
        } else {
            context.insert(ClipOverlayDefaults(styleData: data))
        }
        try? context.save()
        style = new
    }

    /// Back to the built-in look — removes the row, so a backup carries "no custom default".
    func reset() {
        guard let context else { return }
        for row in (try? context.fetch(FetchDescriptor<ClipOverlayDefaults>())) ?? [] { context.delete(row) }
        try? context.save()
        style = .builtIn
    }
}
