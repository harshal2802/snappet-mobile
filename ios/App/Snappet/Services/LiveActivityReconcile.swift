import Foundation

/// **Which Live Activities to keep** (prompt 198). iOS keeps a Live Activity on the Lock Screen after the app that
/// started it is gone — a crash, the system closing it in the background, a relaunch — and the controller only knew
/// the one it started in the CURRENT run, so ending a session left the older one showing "session on", and resuming
/// requested a second one beside it. Every running activity is reconciled against the session that is actually
/// running: keep the one that belongs to it (same start, to the second), end every other. Pure.
enum LiveActivityReconcile {
    struct Running: Equatable, Sendable {
        let id: String
        let startedAt: Date
    }

    struct Plan: Equatable, Sendable {
        /// The activity to keep (adopt) — the running session's — or nil.
        var keep: String?
        /// Every other activity — orphans to end.
        var end: [String]
    }

    static func plan(running: [Running], activeSessionStartedAt: Date?) -> Plan {
        guard let start = activeSessionStartedAt else { return Plan(keep: nil, end: running.map(\.id)) }
        let keep = running.first { abs($0.startedAt.timeIntervalSince(start)) < 1 }?.id
        return Plan(keep: keep, end: running.map(\.id).filter { $0 != keep })
    }
}
