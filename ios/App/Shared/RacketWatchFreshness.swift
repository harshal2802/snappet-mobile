import Foundation

// MARK: - The Watch never keeps a racket face the phone has left (prompt 265, F10) — pure, Shared/
//
// After a phone app kill mid-match nothing on the phone is attached to the match any more, so it never sent `.clear`
// and the Watch kept the racket face with taps going nowhere. Two ways out, both pure and tested on the phone's test
// target (`WorkoutBrokenLinksTests`):
// - the phone says so: at launch (WatchConnectivity activation, nothing attached yet) and when a session ends it sends
//   `clearAll(through: revision)`; a tap for a match the phone has no screen for gets `.clear` for that match;
// - the Watch notices on its own: a tap sent to a REACHABLE phone that gets no answer (no newer snapshot) within
//   `answerWindowSec` drops the face. The next snapshot from the phone brings it back, and the tap itself is queued, so
//   nothing is lost.

/// The Watch's bookkeeping for "is the phone still showing this?" (held by `RacketWatchModel`).
struct RacketWatchFreshness: Equatable, Sendable {
    /// How long a tap may wait for the phone's answer before the Watch leaves the racket face.
    static let answerWindowSec: TimeInterval = 15

    /// Snapshots at or below this revision are gone (the phone cleared them, or the Watch left them).
    private(set) var clearedThrough: Int?
    /// The oldest tap the phone hasn't answered yet.
    private(set) var unansweredTapAt: Date?

    init(clearedThrough: Int? = nil, unansweredTapAt: Date? = nil) {
        self.clearedThrough = clearedThrough
        self.unansweredTapAt = unansweredTapAt
    }

    /// A snapshot may show only if it is newer than the last clear (a queued old one arriving late can't bring a
    /// stale face back).
    func admits(_ state: RacketWatchState) -> Bool {
        guard let c = clearedThrough else { return true }
        return state.revision > c
    }

    /// `clearAll(through:)` drops the face shown unless that face is newer than the clear (a match the phone opened
    /// again after the clear was queued).
    static func clearAllDrops(_ current: RacketWatchState?, through revision: Int) -> Bool {
        guard let current else { return false }
        return current.revision <= revision
    }

    mutating func cleared(through revision: Int) {
        clearedThrough = max(clearedThrough ?? revision, revision)
        unansweredTapAt = nil
    }

    /// The phone answered (a snapshot for the face shown, or a clear).
    mutating func heard() { unansweredTapAt = nil }

    /// Only a tap sent to a reachable phone waits for an answer. Out of range the tap is queued (it is applied when
    /// the phone is back) and the face stays, so scoring from the wrist works with the phone left in a bag.
    static func waitsForAnAnswer(phoneReachable: Bool) -> Bool { phoneReachable }

    /// A tap went to the phone.
    mutating func tapped(at date: Date) {
        if unansweredTapAt == nil { unansweredTapAt = date }
    }

    /// The phone hasn't answered a tap for `answerWindowSec`: leave the racket face.
    func isStale(now: Date) -> Bool {
        guard let t = unansweredTapAt else { return false }
        return now.timeIntervalSince(t) >= Self.answerWindowSec
    }
}

/// The phone's side: when to tell the Watch that no racket screen is up.
enum RacketWatchClearRule {
    /// A session ending (finish, discard, delete) or the phone launching clears the Watch unless a racket screen of
    /// ANOTHER session is attached right now. `ending` nil ⇒ launch / activation (no session named).
    static func broadcasts(attached: UUID?, ending: Set<UUID>?) -> Bool {
        guard let attached else { return true }
        guard let ending else { return false }
        return ending.contains(attached)
    }

    /// A Watch tap for a match / drill the phone has no screen for is answered with `.clear` for it, never dropped.
    static func answersWithClear(commandFor sessionID: UUID, attached: UUID?) -> Bool {
        sessionID != attached
    }
}
