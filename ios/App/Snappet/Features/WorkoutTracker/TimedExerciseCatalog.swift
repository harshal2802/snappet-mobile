import Foundation
import SwiftData

/// A category a timed exercise belongs to — drives the section grouping in the pick-or-create sheet and
/// a glyph on each row. Stored raw on the `@Model` (like every other enum-as-string in this layer) so an
/// unknown future value survives a backup round-trip verbatim.
enum TimedExerciseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case hangboard, core, legs, other
    var id: String { rawValue }
    var display: String {
        switch self {
        case .hangboard: return "Hangboard"
        case .core:      return "Core"
        case .legs:      return "Legs"
        case .other:     return "Other"
        }
    }
    /// SF Symbol for the category (the row glyph / suggestion chip).
    var symbol: String {
        switch self {
        case .hangboard: return "hand.raised.fingers.spread.fill"
        case .core:      return "figure.core.training"
        case .legs:      return "figure.strengthtraining.functional"
        case .other:     return "timer"
        }
    }
}

/// A **named, reusable timed exercise** — the timed analogue of a saved climb. Selecting/creating one in
/// the `PickTimedExerciseSheet` drops a named `.duration` `SessionExercise` onto the freeform canvas, and
/// a "Save to my exercises" toggle persists it here so it shows up in later sessions' **recents**.
///
/// Persisted in the shared SwiftData store: registered in `SnappetSchema.models` AND mirrored by a Row in
/// `SnappetBackup` (the enforced backup invariant — `SnappetBackupTests` fails until both are wired).
/// The structure lives in `specData` (an encoded `TimedExerciseSpec`) rather than a fan of columns, so the
/// `TimedExerciseSpec` value type stays the single source of truth for the structure shape and adding a
/// mode never migrates this model.
@Model
final class TimedExerciseCatalog {
    /// Stable id, used for the pick-row accessibility identifier and dedupe.
    var id: UUID
    var name: String
    /// `TimedExerciseCategory.rawValue` (kept raw — unknown values survive a backup verbatim).
    var categoryRaw: String
    /// An encoded `TimedExerciseSpec`; `nil` ⇒ a plain open count-up (legacy/default).
    var specData: Data?
    var createdAt: Date
    /// Bumped each time the exercise is dropped into a session — drives the recents ordering.
    var lastUsedAt: Date?

    init(id: UUID = UUID(), name: String, category: TimedExerciseCategory = .other,
         spec: TimedExerciseSpec? = nil, createdAt: Date = .now, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.specData = spec.flatMap { try? JSONEncoder().encode($0) }
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// The category (defaults to `.other` for an unknown stored value).
    var category: TimedExerciseCategory {
        get { TimedExerciseCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    /// The decoded structure (`nil` ⇒ an open count-up).
    var spec: TimedExerciseSpec? {
        get { specData.flatMap { try? JSONDecoder().decode(TimedExerciseSpec.self, from: $0) } }
        set { specData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

// MARK: - Seeded built-ins

extension TimedExerciseCatalog {
    /// A built-in suggestion shown in the pick sheet before the user has saved anything of their own.
    /// Kept **in-memory** (not seeded into the store) so the catalog is never an empty void without
    /// writing rows the user didn't ask for — picking one still drops a fully-formed named card, and the
    /// "Save to my exercises" toggle is how a suggestion graduates into a persisted `TimedExerciseCatalog`.
    struct Suggestion: Identifiable, Hashable, Sendable {
        let key: String
        let name: String
        let category: TimedExerciseCategory
        let spec: TimedExerciseSpec
        var id: String { key }
    }

    /// The seeded suggestions (7 s max hang, dead hang, plank, wall sit, repeaters, tabata) — a small,
    /// opinionated starting set spanning the categories so the sheet always has something to pick.
    static let suggestions: [Suggestion] = [
        Suggestion(key: "seed.freehold", name: "Free hold",
                   category: .other, spec: TimedExerciseSpec(mode: .openCountUp)),
        Suggestion(key: "seed.maxhang7", name: "7s max hang",
                   category: .hangboard, spec: .maxHang7),
        Suggestion(key: "seed.deadhang", name: "Dead hang",
                   category: .hangboard, spec: .hold(30)),
        Suggestion(key: "seed.repeaters", name: "Repeaters 7:3 × 6",
                   category: .hangboard, spec: .repeaters7x3x6),
        Suggestion(key: "seed.plank", name: "Plank",
                   category: .core, spec: .hold(60)),
        Suggestion(key: "seed.wallsit", name: "Wall sit",
                   category: .legs, spec: .hold(45)),
        Suggestion(key: "seed.tabata", name: "Tabata",
                   category: .core, spec: .tabata),
    ]
}
