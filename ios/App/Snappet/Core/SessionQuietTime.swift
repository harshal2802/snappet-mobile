import Foundation

/// While a workout or board session is running, the app does no cloud work on its own: no automatic
/// backup, no clip copies, no library scan (prompt 279). Reading the whole store and uploading in the
/// middle of a session warmed the phone and could get the app closed in the background, which lost the
/// session screen.
enum SessionQuietTime {
    /// An unfinished session older than this was abandoned, not running — it must not hold backups off forever.
    static let longestSession: TimeInterval = 12 * 60 * 60

    /// - Parameters:
    ///   - unfinishedStarts: start times of sessions the store holds with no end.
    ///   - liveActivityRunning: a session's Live Activity is on the Lock Screen.
    static func isRunning(unfinishedStarts: [Date], liveActivityRunning: Bool, now: Date) -> Bool {
        if liveActivityRunning { return true }
        return unfinishedStarts.contains { $0 <= now && now.timeIntervalSince($0) < longestSession }
    }
}

/// Cloud work that was held for a session starts again when the session ends (prompt 292). Nothing in the
/// app announces "the session ended" in one place (gym and board end separately, with or without a Live
/// Activity), so this asks every few seconds — only while something is actually being held.
@MainActor
final class SessionEndWatch {
    private var task: Task<Void, Never>?

    var isWatching: Bool { task != nil }

    /// Start watching; a second call while one watch is on does nothing. `onEnd` runs once, the first
    /// time `isRunning` says no.
    func start(every interval: Duration = .seconds(15),
               isRunning: @escaping @MainActor () -> Bool,
               onEnd: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                if !isRunning() {
                    self?.task = nil   // before `onEnd`: it may need to start a new watch
                    await onEnd()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// A fresh start of the app while a workout is still running goes straight back to its screen
/// (prompt 279). iOS can close the app behind a long session; the person left a workout, and that is
/// where they expect to return — by the app icon as much as by the session's banner.
enum SessionReturn {
    /// Older than this, the workout was more likely forgotten than left for a moment: Home's
    /// "Resume" card still offers it, the app just does not jump there by itself.
    static let reopenWithin: TimeInterval = 4 * 60 * 60

    /// - Parameters:
    ///   - runningStart: when the unfinished workout started, if there is one.
    ///   - alreadyRouted: a link or shortcut that started the app has already chosen a destination.
    static func shouldReopen(runningStart: Date?, now: Date, alreadyRouted: Bool) -> Bool {
        guard let start = runningStart, !alreadyRouted else { return false }
        return start <= now && now.timeIntervalSince(start) < reopenWithin
    }

    enum Destination: Equatable, Sendable { case workout, kilter }

    /// Which running session a fresh start returns to (prompt 285): the gym workout's player or the
    /// Kilter board. With both unfinished, the one started last is the one the person is in.
    static func destination(workoutStart: Date?, kilterStart: Date?, now: Date, alreadyRouted: Bool) -> Destination? {
        let workout = shouldReopen(runningStart: workoutStart, now: now, alreadyRouted: alreadyRouted) ? workoutStart : nil
        let kilter = shouldReopen(runningStart: kilterStart, now: now, alreadyRouted: alreadyRouted) ? kilterStart : nil
        switch (workout, kilter) {
        case (nil, nil): return nil
        case (_?, nil): return .workout
        case (nil, _?): return .kilter
        case let (w?, k?): return k > w ? .kilter : .workout
        }
    }
}
