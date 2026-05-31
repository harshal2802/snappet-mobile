import Foundation

/// The bundled exercise catalog (873 exercises from the Free Exercise DB, shipped as
/// `exercises.json` in the app bundle so the app works fully offline — the on-device-only
/// constraint). Loaded once, lazily, and cached. Remote exercise photos are intentionally
/// dropped on iOS; the UI uses category SF Symbols instead.
enum ExerciseCatalog {
    /// All bundled exercises, sorted by name. Decoded on first access.
    @MainActor static let all: [Exercise] = load()

    /// Fast id → exercise lookup for the bundled set.
    @MainActor static let byID: [String: Exercise] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    @MainActor private static func load() -> [Exercise] {
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Exercise].self, from: data)
        else {
            assertionFailure("exercises.json missing from bundle")
            return []
        }
        return decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Active filter state for the exercise browser (value type so it diffs cleanly in SwiftUI).
struct ExerciseFilters: Equatable {
    var categories: Set<ExerciseCategory> = []
    var levels: Set<ExerciseLevel> = []
    var equipment: Set<Equipment> = []
    var muscles: Set<Muscle> = []

    var isEmpty: Bool {
        categories.isEmpty && levels.isEmpty && equipment.isEmpty && muscles.isEmpty
    }
    var activeCount: Int {
        categories.count + levels.count + equipment.count + muscles.count
    }
    mutating func clear() { self = ExerciseFilters() }

    func matches(_ e: Exercise) -> Bool {
        if !categories.isEmpty && !categories.contains(e.category) { return false }
        if !levels.isEmpty && !levels.contains(e.level) { return false }
        if !equipment.isEmpty {
            guard let eq = e.equipment, equipment.contains(eq) else { return false }
        }
        if !muscles.isEmpty {
            let exMuscles = Set(e.allMuscles)
            if muscles.isDisjoint(with: exMuscles) { return false }
        }
        return true
    }
}

enum ExerciseSearch {
    /// Filter + free-text search over a merged exercise list. Search matches the name and
    /// muscle names, case/diacritic-insensitively, requiring every whitespace-separated token.
    static func apply(_ exercises: [Exercise], query: String, filters: ExerciseFilters) -> [Exercise] {
        let tokens = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return exercises.filter { ex in
            guard filters.matches(ex) else { return false }
            guard !tokens.isEmpty else { return true }
            let haystack = ([ex.name] + ex.allMuscles.map(\.display) + [ex.equipment?.display ?? ""])
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}
