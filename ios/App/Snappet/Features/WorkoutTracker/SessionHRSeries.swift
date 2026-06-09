import Foundation
import SwiftData

/// Resolves a session's persisted HR series for the **shared** media editors (the clip editor + the
/// multi-clip Studio), which are used by BOTH WorkoutTracker workouts and Kilter board sessions. A
/// `SessionMedia.sessionID` therefore points at either a `WorkoutSession` or a `KilterSession`, so the
/// editors must check both — looking up only `WorkoutSession` left the HR overlay empty for Kilter
/// clips (decisions.md 2026-06-05). Returns the first non-empty series, or `[]` when neither has HR.
enum SessionHRSeries {
    static func forSession(_ sid: UUID, in context: ModelContext) -> [HRPoint] {
        if let w = try? context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == sid })).first,
           !w.hrSeries.isEmpty { return w.hrSeries }
        if let k = try? context.fetch(
            FetchDescriptor<KilterSession>(predicate: #Predicate { $0.id == sid })).first,
           !k.hrSeries.isEmpty { return k.hrSeries }
        return []
    }

    /// `true` while the session is still **live** (workout not finished / Kilter not ended). The
    /// persisted `hrSeries` is only flushed at finish (`finishWorkout` / Kilter `end`), so an empty
    /// series on a *live* session means "not flushed yet" — and the live coordinator buffer is the
    /// right fallback so a clip opened mid-session still shows HR (the `wt-clip-no-sync` gap: unlike
    /// Kilter, the WorkoutTracker has no mid-session `syncLiveHR`). A completed session with an empty
    /// series genuinely recorded no HR — no fallback (a stale buffer may belong to another session).
    static func isActive(_ sid: UUID, in context: ModelContext) -> Bool {
        if let w = try? context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == sid })).first {
            return w.completedAt == nil
        }
        if let k = try? context.fetch(
            FetchDescriptor<KilterSession>(predicate: #Predicate { $0.id == sid })).first {
            return k.endedAt == nil
        }
        return false
    }

    /// The persisted series, or — for a still-live session whose series isn't flushed yet — the live
    /// coordinator buffer (both transports merged, see `LiveHRMerge`, so a mid-session source switch
    /// doesn't drop the earlier transport's samples). Read-only; never persists. `liveSamples` is the
    /// merged `[HRPoint]` the caller pulls from `AppModel.liveWorkout` (the VM/view has it; this type
    /// stays free of the coordinator).
    static func forSession(_ sid: UUID, in context: ModelContext,
                           liveSamples: @autoclosure () -> [HRPoint]) -> [HRPoint] {
        let persisted = forSession(sid, in: context)
        guard persisted.isEmpty, isActive(sid, in: context) else { return persisted }
        return liveSamples()
    }
}
