import Foundation

// MARK: - Five broken links and stale states in the workout tracker (prompt 265) — pure
//
// Rules for five findings of the workout state-machine review, each a pure function the gym tracker, the shell, the
// scan queue or the Watch relay call, and each tested in `WorkoutBrokenLinksTests`. No SwiftUI / UIKit / Photos here.
//
// | Finding | Rule | Function |
// |---|---|---|
// | F10 | The Watch leaves a racket face the phone has left (launch / session end clear it; an unanswered tap times out) | `Shared/RacketWatchFreshness.swift` |
// | F11 | Deleting a session takes its rally scans out of the queue and cancels its running one, writing nothing | `RacketScanSessionDrop.plan` |
// | F12 | A planned session's Start while a workout runs asks (Go to running workout / Cancel); the plan stays | `PlannedStart.decide` |
// | F13 | A reminder's Start now for a deleted or empty routine says so and lands on the workout home | `ReminderStart.outcome` |
// | F15 | The Live Activity's link opens the running workout, but never over an open player or racket screen | `WorkoutOpenLink.decide` |

// MARK: F11 — a deleted session's scans

enum RacketScanSessionDrop {
    struct Plan: Equatable, Sendable {
        /// Record ids leaving the queue (waiting and running).
        var remove: Set<UUID>
        /// The running scan belongs to the session: cancel it (its result is then dropped).
        var cancelRunning: Bool
    }

    /// `jobs`: (record id, session id) for every scan in the queue, running included.
    static func plan(jobs: [(record: UUID, session: UUID)], running: UUID?, deleting sessionID: UUID) -> Plan {
        let ours = Set(jobs.filter { $0.session == sessionID }.map(\.record))
        return Plan(remove: ours, cancelRunning: running.map { ours.contains($0) } ?? false)
    }
}

// MARK: F12 — Start on a planned session while a workout runs

/// The question asked instead of silently resuming.
struct WorkoutStartConflict: Equatable, Sendable {
    var title: String
    var message: String
    /// Opens the running workout; the plan stays on its screen.
    var goTo: String
    var cancel: String
}

enum PlannedStart {
    enum Decision: Equatable, Sendable {
        /// Nothing is running: start the plan.
        case start
        /// A workout is running: ask. Never resume silently, never replace it (that would delete its work).
        case ask(WorkoutStartConflict)
    }

    /// `running`: the running workout's name, nil when none is.
    static func decide(running: String?) -> Decision {
        guard let running else { return .start }
        let name = running.trimmingCharacters(in: .whitespaces).isEmpty ? "Your workout" : "“\(running)”"
        return .ask(WorkoutStartConflict(
            title: "A workout is already running",
            message: "\(name) is still going. Go to it, or cancel and start this plan after you finish it. "
                + "Your plan stays here.",
            goTo: "Go to running workout",
            cancel: "Cancel"))
    }
}

// MARK: F13 — a reminder's Start now

/// What the gym tracker says when a reminder's routine can't start.
struct RoutineStartNotice: Equatable, Sendable {
    var title: String
    var message: String
}

enum ReminderStart {
    enum Outcome: Equatable, Sendable {
        /// The routine exists and has exercises: the normal start path (a running workout still gets its choice).
        case start
        /// Say why, and land on the workout home.
        case notice(RoutineStartNotice)
    }

    /// `routine`: the routine's name and exercise count, nil when it no longer exists.
    static func outcome(routine: (name: String, exerciseCount: Int)?) -> Outcome {
        guard let routine else {
            return .notice(RoutineStartNotice(
                title: "Routine not found",
                message: "This routine no longer exists. It may have been deleted, so there’s nothing to start."))
        }
        guard routine.exerciseCount > 0 else {
            let name = routine.name.trimmingCharacters(in: .whitespaces).isEmpty ? "This routine" : "“\(routine.name)”"
            return .notice(RoutineStartNotice(
                title: "Nothing to start",
                message: "\(name) has no exercises yet. Add some in Routines, then start it."))
        }
        return .start
    }
}

// MARK: F15 — the Live Activity opens the running workout

enum WorkoutOpenLink {
    enum Decision: Equatable, Sendable {
        /// The player (or a racket recording, drill or game screen on it) is already on screen: do nothing. Opening the
        /// Gym Tracker replaces the navigation stack, which would tear the player and its screens down (prompt 263).
        case stay
        /// Open the Gym Tracker and resume the running workout's player (the workout home if none is running).
        case open
    }

    static func decide(playerOpen: Bool, openCover: LiveCoverKind?) -> Decision {
        playerOpen || openCover != nil ? .stay : .open
    }
}
