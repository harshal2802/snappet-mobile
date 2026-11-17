import Foundation

// MARK: - Heart-rate source ownership (prompt 264) — pure
//
// Three rules from the workout state-machine review about who owns the one live heart-rate source
// (`LiveMetricsCoordinator`), each a pure function the Watch relay, the gym tracker's start paths and the Settings
// picker call, and each tested in `HeartRateOwnershipTests`. No SwiftUI / UIKit / HealthKit here.
//
// | Finding | Rule | Function |
// |---|---|---|
// | F6 | The Watch ending its workout reaches the phone; the phone session keeps running and says "Watch ended" | `WatchEnded` |
// | F7 | A gym session can't start while a Kilter board session is live; the board session is untouched | `GymStartGate` |
// | F8 | The heart-rate source can't be switched while a session is live | `HRSourceLock` |

/// A plain title + message the view shows as it is.
struct OwnershipNotice: Equatable, Sendable {
    var title: String
    var message: String
}

// MARK: F6 — the Watch ended its workout

enum WatchEnded {
    /// How far (seconds) the Watch's workout start may sit before the phone session's start and still belong to it.
    /// The Watch starts after the phone asks, so its start is normally later; this only absorbs clock skew between
    /// the two devices. A queued `.ended` from an EARLIER session started before the current one, so it is dropped.
    static let clockSkew: TimeInterval = 10

    /// Whether the phone takes a Watch "ended" message.
    /// - `sessionStart`: the start of the session the phone's Watch path is recording (nil: nothing is recording).
    /// - `watchStartedAt`: the Watch workout's start carried by the message (nil: an older Watch app, trusted).
    /// - `alreadyEnded`: the Watch already said so for this session (a re-sent copy changes nothing).
    static func accepts(sessionStart: Date?, watchStartedAt: Date?, alreadyEnded: Bool) -> Bool {
        guard let sessionStart, !alreadyEnded else { return false }
        guard let watchStartedAt else { return true }
        return watchStartedAt >= sessionStart.addingTimeInterval(-clockSkew)
    }

    /// What the live player shows about the Watch.
    enum Display: Equatable, Sendable {
        /// Nothing: the Watch is recording, or the session doesn't use it.
        case none
        /// The notice with "Keep going" (not yet dismissed).
        case notice
        /// After "Keep going": a small "Watch ended" chip where the heart-rate chip was.
        case chip
    }

    /// - `watchIsSource`: the session's heart rate comes from the Apple Watch (not a band).
    /// - `ended`: the Watch said its workout ended during this session.
    /// - `dismissed`: the user tapped "Keep going".
    static func display(watchIsSource: Bool, ended: Bool, dismissed: Bool) -> Display {
        guard watchIsSource, ended else { return .none }
        return dismissed ? .chip : .notice
    }

    static let notice = OwnershipNotice(
        title: "Watch ended",
        message: "Your Apple Watch stopped its workout, so heart rate isn't coming from it any more. "
            + "This session is still running here. Finish it when you're done.")
    /// The notice's one button: dismiss it and carry on.
    static let keepGoing = "Keep going"
    /// The chip that stays after "Keep going".
    static let chip = "Watch ended"
}

// MARK: F7 — a gym start while a Kilter board session is live

enum GymStartGate {
    /// nil ⇒ start the gym session. Otherwise refuse with this notice: the live board session owns the heart-rate
    /// source, and a second session would take it over (F7). Nothing about the board session changes.
    static func refusal(boardSessionLive: Bool) -> OwnershipNotice? {
        guard boardSessionLive else { return nil }
        return OwnershipNotice(
            title: "A board session is running",
            message: "Your Kilter board session is still going and is recording your heart rate. "
                + "Finish it in Kilter Board first, then start this workout.")
    }
}

// MARK: F8 — switching the heart-rate source mid-session

enum HRSourceLock {
    /// nil ⇒ the source can be switched. Otherwise the line the picker shows under its disabled rows.
    /// - `metricsRunning`: a session is driving the live source (`LiveMetricsCoordinator.isSessionActive`).
    /// - `workoutLive`: a gym workout is open (it may not have restarted its source yet after a relaunch).
    /// - `boardLive`: a Kilter board session is open.
    static func reason(metricsRunning: Bool, workoutLive: Bool, boardLive: Bool) -> String? {
        guard metricsRunning || workoutLive || boardLive else { return nil }
        return "You can't change the heart-rate source while a session is live. "
            + "Finish the session first, then switch."
    }
}
