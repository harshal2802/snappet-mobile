import Foundation

/// Pure, device-free **builder + faceted filter** for the workout library (workout-redesign E3). Merges the
/// three previously-disconnected "libraries" (the bundled strength catalog, the timed catalog, the climb/run
/// starter templates) into one discipline-spined `[LibraryItem]`, and applies the discipline-aware filter
/// whose facets **swap by active discipline** (strength → muscle/equipment; climb → grade-style; timed →
/// protocol-category; run → terrain). No SwiftUI/SwiftData here — the I/O edge (`ExerciseResolver`) feeds it
/// value snapshots and the views just render the result. Unit-tested in `SnappetTests`.
enum LibraryBuilder {

    /// A value snapshot of a saved `TimedExerciseCatalog` row (the builder must stay off the `@Model` so it
    /// is testable without a store; the I/O edge maps the live rows to these).
    struct TimedSnapshot: Hashable, Sendable {
        let id: UUID
        let name: String
        let category: TimedExerciseCategory
        let specData: Data?
        let lastUsedAt: Date?
    }

    /// Build the full library from value inputs. `strength` is the merged bundled+custom exercise list (the
    /// `ExerciseResolver.allMerged` output); `timed` the saved timed-catalog snapshots. Seeded timed
    /// suggestions and the climb/run starters are folded in so every discipline has at least a starting set.
    static func items(strength: [Exercise], timed: [TimedSnapshot]) -> [LibraryItem] {
        var out: [LibraryItem] = []

        // Strength (bundled + custom). `category` maps to a discipline at the seam below.
        for ex in strength {
            out.append(LibraryItem(
                id: ex.id, title: ex.name, subtitle: ex.subtitle,
                discipline: discipline(for: ex.category), symbol: ex.category.symbol,
                isCustom: ex.isCustom, source: .strength(ex)))
        }

        // Timed — saved rows first, then the seeded suggestions whose name isn't already saved.
        let savedNames = Set(timed.map { $0.name.lowercased() })
        for t in timed {
            out.append(LibraryItem(
                id: "timed:\(t.id.uuidString)", title: t.name,
                subtitle: timedSubtitle(t.category, specData: t.specData),
                discipline: .timed, symbol: t.category.symbol, isCustom: false,
                source: .timed(specData: t.specData, category: t.category, catalogID: t.id)))
        }
        for s in TimedExerciseCatalog.suggestions where !savedNames.contains(s.name.lowercased()) {
            out.append(LibraryItem(
                id: "timed.seed:\(s.key)", title: s.name,
                subtitle: timedSubtitle(s.category, spec: s.spec),
                discipline: .timed, symbol: s.category.symbol, isCustom: false,
                source: .timed(specData: try? JSONEncoder().encode(s.spec),
                               category: s.category, catalogID: nil)))
        }

        // Climb + run starter templates (in-memory — no @Model, per the E3 scope decision).
        for c in ClimbStarter.all {
            out.append(LibraryItem(
                id: c.key, title: c.name, subtitle: "\(c.climbType.label) · \(c.gradeBand)",
                discipline: .climb, symbol: c.climbType.symbol, isCustom: false, source: .climb(c)))
        }
        for r in RunStarter.all {
            out.append(LibraryItem(
                id: r.key, title: r.name, subtitle: runSubtitle(r),
                discipline: .run, symbol: WorkoutDiscipline.run.symbol, isCustom: false, source: .run(r)))
        }
        return out
    }

    /// The library's top facet = a row of disciplines. Only those with at least one item are shown,
    /// in the canonical order (strength, climb, run, timed, dance, other).
    static func disciplines(in items: [LibraryItem]) -> [WorkoutDiscipline] {
        let present = Set(items.map(\.discipline))
        return WorkoutDiscipline.allCases.filter { present.contains($0) }
    }

    // MARK: - Search + faceted filter

    /// Free-text + faceted filter over the library. `discipline == nil` ⇒ "All types". The facets that
    /// apply depend on the active discipline (the swap is the E3 win); irrelevant facets are simply ignored
    /// for items of another discipline, so an "All types" search still works across everything.
    static func apply(_ items: [LibraryItem], query: String,
                      discipline: WorkoutDiscipline?, facets: LibraryFacets) -> [LibraryItem] {
        let tokens = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return items.filter { item in
            if let discipline, item.discipline != discipline { return false }
            guard facets.matches(item) else { return false }
            guard !tokens.isEmpty else { return true }
            let haystack = (item.title + " " + item.subtitle)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: - Seams (the two "type" vocabularies reconciled — README §10 Q6)

    /// Map an `ExerciseCategory` (the `exercises.json` vocabulary) onto a `WorkoutDiscipline` (the redesign's
    /// identity axis). Cardio → run; everything else (strength/powerlifting/olympic/strongman/plyo/stretch)
    /// stays strength — the bundled DB is a strength catalog, so we don't over-fragment it.
    static func discipline(for category: ExerciseCategory) -> WorkoutDiscipline {
        switch category {
        case .cardio: return .run
        case .strength, .powerlifting, .olympicWeightlifting, .strongman, .plyometrics, .stretching:
            return .strength
        }
    }

    private static func timedSubtitle(_ category: TimedExerciseCategory, spec: TimedExerciseSpec?) -> String {
        let s = (spec ?? TimedExerciseSpec(mode: .openCountUp)).summary
        return "\(category.display) · \(s)"
    }
    private static func timedSubtitle(_ category: TimedExerciseCategory, specData: Data?) -> String {
        let spec = specData.flatMap { try? JSONDecoder().decode(TimedExerciseSpec.self, from: $0) }
        return timedSubtitle(category, spec: spec)
    }
    private static func runSubtitle(_ r: RunStarter) -> String {
        if let m = r.distanceMeters {
            let km = (m / 1000).rounded()
            return "\(r.terrain.display) · \(Int(km)) km"
        }
        return r.terrain.display
    }
}

/// Pure, **best-effort** records derivation for the library detail's discipline-adaptive records header
/// (E3). Reads what's cheaply available from the persisted session blobs — there is **no** per-movement
/// cross-session history `@Model` yet (deferred, README §9), so these are session-scoped aggregates, not a
/// true time series. Strength reuses the exact `WorkoutMath` figures; climb/timed/run scan the `.run`/
/// `.climb`/`.duration` entities for a best-of. Each record is a `(value, label)` pair, ready for a
/// `StatRibbon`. Empty when the discipline was never logged. No SwiftUI/SwiftData → unit-tested.
enum LibraryRecords {
    struct Record: Equatable, Sendable { let value: String; let label: String }

    /// The records for a library item, given the user's completed history. For a strength item the records
    /// are keyed on its `exerciseId`; for climb/run/timed they are discipline-wide (no per-template id in the
    /// blobs yet — the honest limitation), and the `item`'s climb style / run terrain refines nothing today.
    static func records(for item: LibraryItem, history: [WorkoutSession], unit: WeightUnit) -> [Record] {
        switch item.source {
        case .strength(let ex):
            return strength(exerciseId: ex.id, history: history, unit: unit)
        case .climb:
            return climb(history: history)
        case .run:
            return run(history: history, unit: unit)
        case .timed:
            return timed(history: history)
        }
    }

    static func strength(exerciseId: String, history: [WorkoutSession], unit: WeightUnit) -> [Record] {
        let sessions = WorkoutMath.sessionCount(history: history, exerciseId: exerciseId)
        guard sessions > 0 else { return [] }
        var out: [Record] = []
        if let top = WorkoutMath.topSet(history: history, exerciseId: exerciseId) {
            let v = top.bestKg > 0
                ? "\(WorkoutMath.formatWeight(kg: top.bestKg, unit: unit)) \(unit.display) × \(top.bestReps)"
                : "\(top.bestReps) reps"
            out.append(Record(value: v, label: "Best set"))
        }
        let vol = WorkoutMath.totalVolumeKg(history: history, exerciseId: exerciseId)
        if vol > 0 { out.append(Record(value: WorkoutMath.formatVolume(kg: vol, unit: unit), label: "Volume")) }
        out.append(Record(value: "\(sessions)", label: "Sessions"))
        return out
    }

    static func climb(history: [WorkoutSession]) -> [Record] {
        var sends = 0, total = 0
        var hardest: (label: String, difficulty: Double)?
        for s in history {
            for ex in s.exercises where ex.discipline == .climb {
                total += 1
                let scale = ex.climbGradeScale
                let didSend = ex.resolvedClimbStatus.map { $0 == .flash || $0 == .sent } ?? false
                if didSend {
                    sends += 1
                    if let label = ex.climbGradeLabel, let diff = scale.difficulty(for: label),
                       diff > (hardest?.difficulty ?? -1) {
                        hardest = (label, diff)
                    }
                }
            }
        }
        guard total > 0 else { return [] }
        return [Record(value: hardest?.label ?? "—", label: "Hardest send"),
                Record(value: "\(sends)", label: "Sends"),
                Record(value: "\(total)", label: "Climbs")]
    }

    static func run(history: [WorkoutSession], unit: WeightUnit) -> [Record] {
        var meters = 0.0, seconds = 0.0, runs = 0
        var longest = 0.0
        for s in history {
            var sessionMeters = 0.0
            for ex in s.exercises where ex.discipline == .run {
                for set in ex.sets where set.completedAt != nil {
                    meters += set.distanceMeters ?? 0
                    seconds += set.durationSec ?? 0
                    sessionMeters += set.distanceMeters ?? 0
                }
            }
            if sessionMeters > 0 { runs += 1; longest = max(longest, sessionMeters) }
        }
        guard runs > 0 else { return [] }
        let du: DistanceUnit = unit == .lb ? .mi : .km
        let pace = (meters > 0 && seconds > 0)
            ? SetMeasure.formatPace(secPerKm: seconds / (meters / 1000), unit: du) : "—"
        return [Record(value: SetMeasure.formatDistance(meters, unit: du), label: "Total distance"),
                Record(value: pace, label: "Avg pace"),
                Record(value: SetMeasure.formatDistance(longest, unit: du), label: "Longest")]
    }

    static func timed(history: [WorkoutSession]) -> [Record] {
        var totalSeconds = 0.0, sets = 0, best = 0.0
        for s in history {
            for ex in s.exercises where ex.discipline == .timed {
                for set in ex.sets where set.completedAt != nil {
                    let d = set.durationSec ?? 0
                    totalSeconds += d; sets += 1; best = max(best, d)
                }
            }
        }
        guard sets > 0 else { return [] }
        return [Record(value: SetMeasure.formatDuration(best), label: "Best hold"),
                Record(value: SetMeasure.formatDuration(totalSeconds), label: "Total time"),
                Record(value: "\(sets)", label: "Sets")]
    }
}

/// The **discipline-adaptive** filter state. Holds a set per facet kind; only the sets relevant to the
/// active discipline are surfaced in the filter sheet, so the SAME value type drives a strength filter
/// (muscle + equipment) and a climb filter (style) and a timed filter (category) and a run filter (terrain).
/// Value type → diffs cleanly in SwiftUI; pure → unit-tested.
struct LibraryFacets: Equatable, Sendable {
    // Strength facets (reuse the existing taxonomy).
    var muscles: Set<Muscle> = []
    var equipment: Set<Equipment> = []
    /// Strength-only convenience facet: "no equipment" = body-only / unset (a research staple).
    var noEquipment: Bool = false
    // Climb facet — the style (boulder vs roped).
    var climbTypes: Set<ClimbType> = []
    // Timed facet — the protocol category.
    var timedCategories: Set<TimedExerciseCategory> = []
    // Run facet — the terrain.
    var runTerrains: Set<RunTerrain> = []

    var isEmpty: Bool {
        muscles.isEmpty && equipment.isEmpty && !noEquipment
            && climbTypes.isEmpty && timedCategories.isEmpty && runTerrains.isEmpty
    }
    var activeCount: Int {
        muscles.count + equipment.count + (noEquipment ? 1 : 0)
            + climbTypes.count + timedCategories.count + runTerrains.count
    }
    mutating func clear() { self = LibraryFacets() }

    /// Drop the facets that don't apply to a discipline — called when the active discipline chip changes,
    /// so a stale strength-muscle filter never silently hides every climb.
    mutating func keepOnly(_ discipline: WorkoutDiscipline?) {
        guard let discipline else { return }   // "All types" keeps every facet
        if discipline != .strength { muscles = []; equipment = []; noEquipment = false }
        if discipline != .climb { climbTypes = [] }
        if discipline != .timed { timedCategories = [] }
        if discipline != .run { runTerrains = [] }
    }

    func matches(_ item: LibraryItem) -> Bool {
        switch item.source {
        case .strength(let ex):
            if !muscles.isEmpty && muscles.isDisjoint(with: Set(ex.allMuscles)) { return false }
            if noEquipment {
                // Body-only or no equipment tagged.
                if let eq = ex.equipment, eq != .bodyOnly { return false }
            }
            if !equipment.isEmpty {
                guard let eq = ex.equipment, equipment.contains(eq) else { return false }
            }
            return true
        case .climb(let c):
            return climbTypes.isEmpty || climbTypes.contains(c.climbType)
        case .timed(_, let category, _):
            return timedCategories.isEmpty || timedCategories.contains(category)
        case .run(let r):
            return runTerrains.isEmpty || runTerrains.contains(r.terrain)
        }
    }
}
