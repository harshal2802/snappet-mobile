import Foundation

/// Where the racket card goes on a session's recap and finished-session detail (prompt 262, review finding F9).
///
/// Your videos, Edit match, Keep rallies only… and a game's heart rate are offered only by `RacketRecapCards`. Before
/// this, the recap rendered that card only when racket was the dominant discipline (most completed sets), and the
/// detail only for workout types timed / run / other (most exercises) — so a match plus two lifts showed no racket card
/// and its videos and editor could not be reached. Now the card shows whenever the session holds a racket entity, in
/// addition to the dominant discipline's own cards, and never twice. Pure: no SwiftUI, no SwiftData fetch.
enum RacketRecapReach {

    /// Whether the session holds a racket entity — a match or a drill (`racketMode` defaults to match, so this is
    /// `discipline == .racket`, the same test `RacketStats.summary` uses for the card itself).
    static func hasRacketEntity(_ exercises: [SessionExercise]) -> Bool {
        exercises.contains { $0.discipline == .racket }
    }

    /// `SessionRecapCards`: add the racket card after the dominant discipline's cards. Racket dominant already renders
    /// it as its own cards, so it is never added a second time.
    static func addsRacketCard(dominant: FreeformSummary.Dominant, exercises: [SessionExercise]) -> Bool {
        dominant != .racket && hasRacketEntity(exercises)
    }

    /// The session detail's per-type section: the strength branch renders no `SessionRecapCards` (it compares each
    /// lift with last time instead), so it adds the racket card itself. Every other branch goes through
    /// `SessionRecapCards`, which decides with `addsRacketCard`.
    static func detailAddsRacketCard(kind: SessionInsights.Kind, exercises: [SessionExercise]) -> Bool {
        kind == .strength && hasRacketEntity(exercises)
    }
}
