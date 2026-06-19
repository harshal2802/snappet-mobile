import Foundation

/// **The polymorphic workout-library item** (workout-redesign E3). The Gym Tracker's "Exercises" tab was a
/// flat, strength-only catalog; the library is now organized by workout **TYPE** as the top facet
/// (Apple-Fitness+-style), so a hangboard protocol, a bouldering session, and a 5 km run all have a home
/// beside a bench press. `LibraryItem` is the single, discipline-tagged value type the browse list renders;
/// it **wraps** the existing identity contracts rather than replacing them — the `String exerciseId` that
/// routines/history persist is carried verbatim in `id`, so a `LibraryItem` never changes what is stored.
///
/// Pure (Foundation only — no SwiftUI/SwiftData) so the builder + the filter are unit-tested without a
/// device (the repo's pure-logic-at-a-thin-edge rule). The discipline accent `Color` and the views live in
/// the view layer (`WorkoutLibraryView`).
struct LibraryItem: Identifiable, Hashable, Sendable {
    /// The stable identity. For a strength item this IS the `exerciseId` (bundled catalog id or
    /// `custom-…`); for a timed catalog row it is `timed:<uuid>`; for a climb/run starter template it is
    /// the template's stable key. The browse → detail → routine-builder pipeline keys on this verbatim.
    let id: String
    let title: String
    let subtitle: String
    let discipline: WorkoutDiscipline
    /// SF Symbol for the row glyph + the detail header.
    let symbol: String
    /// `true` for a user-created exercise (a "Custom" badge) — distinct from a built-in catalog item.
    let isCustom: Bool

    /// The kind of backing source this item wraps, so the detail screen knows what it can show and the
    /// routine builder (E4) knows how to seed a block. Carries the underlying value where one exists.
    enum Source: Hashable, Sendable {
        /// A bundled/custom strength exercise — the full `Exercise` taxonomy is available (muscles, etc.).
        case strength(Exercise)
        /// A saved/seeded timed exercise — carries the encoded `TimedExerciseSpec` + category.
        case timed(specData: Data?, category: TimedExerciseCategory, catalogID: UUID?)
        /// An in-memory climb starter template (no `@Model` — see the E3 scope decision).
        case climb(ClimbStarter)
        /// An in-memory run starter template.
        case run(RunStarter)
    }
    let source: Source

    // Identity / equality is the `id` (the rest is derived, snapshot-stable display).
    static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - In-memory climb / run starter templates

/// A built-in **climb** starter shown in the library so the climb discipline isn't an empty void before the
/// user logs anything. Kept **in-memory** (not a saved `@Model`) — the E3 scope decision: a net-new saved
/// template `@Model` would have to be wired into `SnappetSchema` AND `SnappetBackup` with a golden-byte Row
/// mirror, which is out of proportion to seeding a handful of style suggestions. A real, named, saved climb
/// is the freeform "Add a climb" flow's `SessionExercise` (which already persists inside `WorkoutSession`).
/// Mirrors `TimedExerciseCatalog.Suggestion`'s in-memory pattern.
struct ClimbStarter: Identifiable, Hashable, Sendable {
    /// Stable key, prefixed so it never collides with a bundled `exerciseId` (e.g. `climb.boulder`).
    let key: String
    let name: String
    let climbType: ClimbType
    /// A representative grade band for the subtitle (e.g. "V2–V6"); display-only.
    let gradeBand: String
    var id: String { key }

    static let all: [ClimbStarter] = [
        ClimbStarter(key: "climb.boulder", name: "Boulder", climbType: .boulder, gradeBand: "V0–V8"),
        ClimbStarter(key: "climb.topRope", name: "Top-rope route", climbType: .topRope, gradeBand: "5.6–5.12"),
        ClimbStarter(key: "climb.lead", name: "Lead route", climbType: .lead, gradeBand: "5.8–5.13"),
        ClimbStarter(key: "climb.sport", name: "Sport route", climbType: .sport, gradeBand: "5.9–5.14"),
    ]
}

/// A built-in **run** starter shown in the library — distance + terrain suggestions. In-memory for the same
/// reason as `ClimbStarter` (no saved `@Model`); a logged run is a `.run`-discipline `SessionExercise`.
struct RunStarter: Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    /// The terrain facet this template is filed under (road / trail / treadmill / track).
    let terrain: RunTerrain
    /// A suggested distance in metres, for the subtitle + a routine-builder seed; `nil` for an open run.
    let distanceMeters: Double?
    var id: String { key }

    static let all: [RunStarter] = [
        RunStarter(key: "run.easy", name: "Easy run", terrain: .road, distanceMeters: 5000),
        RunStarter(key: "run.long", name: "Long run", terrain: .road, distanceMeters: 10000),
        RunStarter(key: "run.trail", name: "Trail run", terrain: .trail, distanceMeters: 8000),
        RunStarter(key: "run.treadmill", name: "Treadmill run", terrain: .treadmill, distanceMeters: 5000),
        RunStarter(key: "run.intervals", name: "Track intervals", terrain: .track, distanceMeters: nil),
    ]
}

/// The terrain facet for the run filter (the run-discipline analogue of strength's `Equipment`). Pure +
/// display-only — no model impact (a logged run only stores distance/duration).
enum RunTerrain: String, CaseIterable, Identifiable, Hashable, Sendable {
    case road, trail, treadmill, track
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .road:      return "road.lanes"
        case .trail:     return "mountain.2.fill"
        case .treadmill: return "figure.run.treadmill"
        case .track:     return "figure.run.circle"
        }
    }
}
