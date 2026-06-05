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
}
