import AppIntents
import WidgetKit

/// Tick a chore from the household widget without opening the app (household prompt 04), the
/// `ToggleHabitIntent` pattern: it records the desired state in the App-Group outbox and updates the
/// snapshot optimistically; the app turns it into a `complete` / `undo` op on its next foreground.
struct ToggleChoreIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick Off Chore"
    static let description = IntentDescription("Mark one of your household chores done (or not done).")
    static let openAppWhenRun = false

    @Parameter(title: "Chore")
    var choreID: String

    init() {}
    init(choreID: String) { self.choreID = choreID }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: choreID), var snap = HouseholdWidgetStore.read() else { return .result() }
        let current = snap.chores.first { $0.id == id }?.done ?? false
        ChoreOutbox.append(ChoreToggle(choreID: id, desired: !current))
        snap.chores = snap.chores.map { c in
            guard c.id == id else { return c }
            var u = c
            u.done = !current
            return u
        }
        snap.updatedAt = Date()
        HouseholdWidgetStore.write(snap)
        WidgetCenter.shared.reloadTimelines(ofKind: HouseholdWidgetStore.kind)
        return .result()
    }
}
