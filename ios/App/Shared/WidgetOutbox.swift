import Foundation

/// A pending habit check-off the user tapped in a home-screen widget while the app wasn't
/// necessarily running (#81 Phase 2). The interactive `ToggleHabitIntent` writes one to the
/// App-Group outbox; the app drains + reconciles them into SwiftData on its next foreground
/// (`HabitCheckoffReconciler`). Recording the ABSOLUTE `desired` state (not a relative "toggle")
/// keeps reconciliation idempotent and order-tolerant.
struct HabitToggle: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var habitID: UUID
    /// Start-of-day the check-off applies to (the widget's "today" when tapped).
    var day: Date
    /// Whether the habit should end up DONE (true) or not-done (false) for `day`.
    var desired: Bool
    var requestedAt: Date

    init(id: UUID = UUID(), habitID: UUID, day: Date, desired: Bool, requestedAt: Date = Date()) {
        self.id = id
        self.habitID = habitID
        self.day = day
        self.desired = desired
        self.requestedAt = requestedAt
    }
}

/// The App-Group **outbox** for widget-originated habit check-offs (#81 Phase 2).
///
/// A DIRECTORY of one-file-per-toggle (named by the toggle's id) — not a single mutated file — so the
/// widget process and the app process never do a cross-process read-modify-write on the same file (no
/// lost-update race): appending is just writing a new uniquely-named file. The app reads with
/// `pending()`, applies, and removes only the ids it applied (`remove(ids:)`) after a successful
/// save. Degrades to no-op / empty when the App-Group container is unavailable.
enum WidgetOutbox {
    static var directoryURL: URL? {
        WidgetSnapshotStore.containerURL?.appendingPathComponent("habit-outbox", isDirectory: true)
    }

    /// Append one toggle (a new file). No-op if the container is unavailable.
    static func append(_ toggle: HabitToggle) {
        guard let dir = directoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(toggle) else { return }
        try? data.write(to: dir.appendingPathComponent("\(toggle.id.uuidString).json"), options: .atomic)
    }

    /// All pending toggles, sorted by request time (older first) so the app applies them in order.
    /// Does NOT remove them — the app removes only the ids it successfully persisted.
    static func pending() -> [HabitToggle] {
        guard let dir = directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(HabitToggle.self, from: $0) }
            }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    /// Remove the named toggle files (after the app has persisted them). Idempotent.
    static func remove(ids: [UUID]) {
        guard let dir = directoryURL else { return }
        for id in ids {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
        }
    }
}
