import AppIntents

/// A habit exposed to Siri / Shortcuts so `CheckOffHabitIntent` can resolve one by name (#81 Phase 3).
/// Reads the App-Group snapshot (`SnappetWidgetSnapshot.habits` — the full habit list with id + name),
/// so it works OFF-PROCESS with no SwiftData, like the rest of the widget/intent surface.
struct HabitEntity: AppEntity, Identifiable {
    var id: UUID
    var name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
    init(_ item: SnappetWidgetSnapshot.HabitItem) {
        self.id = item.id
        self.name = item.name
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Habit"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let defaultQuery = HabitEntityQuery()
}

/// Resolves `HabitEntity`s from the App-Group snapshot — by id (Shortcuts re-resolution), by name
/// fragment (a spoken "check off Read"), and the full suggestion list (the Shortcuts picker).
struct HabitEntityQuery: EntityStringQuery {
    func entities(for identifiers: [HabitEntity.ID]) async throws -> [HabitEntity] {
        let wanted = Set(identifiers)
        return Self.allHabits().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [HabitEntity] {
        Self.allHabits().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [HabitEntity] {
        Self.allHabits()
    }

    static func allHabits() -> [HabitEntity] {
        (WidgetSnapshotStore.read()?.habits ?? []).map(HabitEntity.init)
    }
}
