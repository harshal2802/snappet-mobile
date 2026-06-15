import Foundation

/// A pending "open the app and do X" action requested by a Siri / Shortcuts App Intent (#81 Phase 3).
/// The off-process intent (`openAppWhenRun = true`) enqueues one of these; the app drains the inbox on
/// foreground (`RootShell`) and dispatches it through the existing `SuiteRouter` deep-link plumbing —
/// so Siri actions reuse the same in-app routing as the `snappet://` URLs, not a new path.
enum PendingAppAction: Codable, Sendable, Equatable {
    /// Open Pomodoro and start the focus timer (reuses `SuiteRouter.pendingPomodoroStart`).
    case startPomodoro
    /// Open a module by id (`SuiteRouter.open(module:)`).
    case openModule(String)
    /// Open Journal and compose a new entry, optionally prefilled with spoken/typed text.
    case quickJournal(String?)
    /// Open the gym tracker to start a routine (a specific-routine auto-launch is a follow-up).
    case startRoutine
}

/// The App-Group **inbox** for those actions (#81 Phase 3). A DIRECTORY of one-file-per-action — the
/// same lock-free pattern as `WidgetOutbox`: enqueueing writes a new uniquely-named file, so the
/// intents process and the app process never do a cross-process read-modify-write on one file.
/// Degrades to no-op / empty when the App-Group container is unavailable.
enum AppActionInbox {
    static var directoryURL: URL? {
        WidgetSnapshotStore.containerURL?.appendingPathComponent("app-action-inbox", isDirectory: true)
    }

    /// One pending action on disk: a stable id for the filename + ordering, plus the action.
    private struct Record: Codable { var id: UUID; var requestedAt: Date; var action: PendingAppAction }

    /// Enqueue an action (a new file). No-op if the container is unavailable.
    static func enqueue(_ action: PendingAppAction, id: UUID = UUID(), requestedAt: Date = Date()) {
        guard let dir = directoryURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Record(id: id, requestedAt: requestedAt, action: action))
        else { return }
        try? data.write(to: dir.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    /// Read + REMOVE all pending actions, oldest first (the app drains on foreground). Removing as we
    /// go is safe: these are fire-and-forget UI navigations, idempotent enough that a rare double-open
    /// is harmless, and never re-applied.
    static func drain() -> [PendingAppAction] {
        guard let dir = directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var records: [Record] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let record = try? JSONDecoder().decode(Record.self, from: data) {
                records.append(record)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return records.sorted { $0.requestedAt < $1.requestedAt }.map(\.action)
    }
}
