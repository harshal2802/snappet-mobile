import Foundation
import HighlightEngine

/// Pure, device-free selector for the Gym Tracker dashboard's **recent-sessions feed** (workout-redesign
/// E1) — the single biggest gap today: a finished session is invisible on the dashboard unless it has a
/// video. Produces a short, mixed-discipline list where each row carries its discipline (for the accent
/// edge-bar + glyph) and a type-adaptive ≤3-fact rollup (a climb shows grade/sends/time, a run shows
/// distance/pace/duration, a lift shows volume/sets/top-set), plus a PR flag. Composes the already-pure
/// `WorkoutDashboardStats.dominantDiscipline`, `FreeformClimbStats`, `FreeformSummary`, `SessionRecap`, and
/// `WorkoutMath` — one definition of every figure. No SwiftUI/SwiftData; unit-tested in `SnappetTests`.
enum RecentSessions {

    struct Row: Identifiable, Equatable, Sendable {
        /// The session id — the deep-link target (`SessionRoute`).
        let id: UUID
        let discipline: WorkoutDiscipline
        let title: String
        let date: Date
        let durationMinutes: Int
        /// Up to three type-adaptive headline facts (values only; ready to render as chips).
        let facts: [String]
        /// A genuine milestone was reached this session (weighted PR or first-send) → show a PR pill.
        let isPR: Bool
    }

    /// The most recent completed sessions as rows (newest first). `limit` caps the feed (default 5).
    static func rows(history: [WorkoutSession], unit: WeightUnit, limit: Int = 5) -> [Row] {
        let completed = history.filter { !$0.isActive }.sorted { $0.startedAt > $1.startedAt }
        return completed.prefix(limit).compactMap { s -> Row? in
            guard let discipline = WorkoutDashboardStats.dominantDiscipline(of: s) else { return nil }
            let prior = completed.filter { $0.startedAt < s.startedAt }
            let isPR = !FreeformSummary.milestones(for: s, history: prior).isEmpty
            return Row(id: s.id, discipline: discipline, title: s.routineName, date: s.startedAt,
                       durationMinutes: max(1, Int(s.duration / 60)),
                       facts: facts(for: s, discipline: discipline, unit: unit), isPR: isPR)
        }
    }

    /// The ≤3 type-adaptive facts for one session.
    static func facts(for s: WorkoutSession, discipline: WorkoutDiscipline, unit: WeightUnit) -> [String] {
        switch discipline {
        case .climb:
            let cs = FreeformClimbStats.stats(for: s, now: s.completedAt ?? s.startedAt, hrSeries: [])
            let wall = cs.timeline.compactMap(\.timeOnClimb).reduce(0, +)
            return [cs.hardestSendGrade ?? "—", "\(cs.sends) sends",
                    wall > 0 ? SetMeasure.formatDuration(wall) : "\(cs.totalClimbs) climbs"]
        case .strength:
            var facts = [WorkoutMath.formatVolume(kg: WorkoutMath.sessionVolumeKg(s), unit: unit),
                         "\(s.completedSetCount) sets"]
            if let top = topSet(s) {
                facts.append("top \(WorkoutMath.formatWeight(kg: top.kg, unit: unit)) \(unit.display) × \(top.reps)")
            }
            return facts
        case .run:
            let t = SessionRecap.runTotals(s)
            let du = SessionRecap.distanceUnit(unit)
            let pace = (t.meters > 0 && t.seconds > 0)
                ? SetMeasure.formatPace(secPerKm: t.seconds / (t.meters / 1000), unit: du) : "—"
            return [SetMeasure.formatDistance(t.meters, unit: du), pace, SetMeasure.formatDuration(t.seconds)]
        case .timed:
            return [SetMeasure.formatDuration(FreeformSummary.holdTimeSeconds(s)),
                    "\(s.completedSetCount) sets", SessionRecap.bestHoldLabel(s)]
        case .dance, .other:
            return [SetMeasure.formatDuration(FreeformSummary.activeSeconds(s, discipline: discipline)),
                    "\(s.completedSetCount) sets"]
        }
    }

    /// The session's heaviest weighted set (for the strength rollup's "top 100 kg × 5").
    private static func topSet(_ s: WorkoutSession) -> (kg: Double, reps: Int)? {
        var best: (kg: Double, reps: Int)? = nil
        for ex in s.exercises where ex.kind == .repsWeight {
            for set in ex.sets where set.completedAt != nil {
                guard let reps = set.actualReps, let weight = set.actualWeight, reps > 0 else { continue }
                let kg = WorkoutMath.toKg(weight, set.weightUnit)
                if best == nil || kg * Double(reps) > best!.kg * Double(best!.reps) { best = (kg, reps) }
            }
        }
        return best
    }
}
