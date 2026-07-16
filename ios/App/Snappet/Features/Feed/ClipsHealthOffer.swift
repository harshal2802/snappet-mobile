import Foundation

// MARK: - Contextual "Connect Apple Health" offer in Clips (highlights P5)
//
// The highlights convergence retired the Workout Reels onboarding — the ONE fresh-install surface
// that primed HealthKit read access — so the watch→Clips import can silently return nothing on a
// new install (decisions.md 2026-07-15). Requesting from the launch reconcile was tried and
// REVERTED (an unsolicited system sheet on every launch until answered; races UI tests), so the
// gap closes here instead: a dismissible card in the Clips feed whose Health request fires ONLY
// from an explicit user tap.
//
// PURE decision logic (no HealthKit, no UserDefaults) so it unit-tests in `SnappetTests` with no
// simulator; the view supplies the two inputs from its existing @Query + an @AppStorage flag.

enum ClipsHealthOffer {
    /// The persisted asked-or-dismissed flag's UserDefaults key. ONE flag covers both outcomes
    /// deliberately: HealthKit read-authorization status is NOT queryable (Apple hides read
    /// grants), so "the user answered the sheet" and "the user waved the card away" are equally
    /// final — the card never returns either way. Cleared by `SnappetApp` under a fresh-store
    /// launch so UI tests are deterministic.
    static let resolvedKey = "clips.healthOffer.resolved"

    /// Whether the Clips feed shows the offer card: only while the gap it closes is still open
    /// (no Apple-Watch-imported session exists yet — one appearing means read access works) and
    /// the user hasn't already connected or dismissed.
    static func shouldShow(hasWatchImportedSession: Bool, resolved: Bool) -> Bool {
        !hasWatchImportedSession && !resolved
    }
}
