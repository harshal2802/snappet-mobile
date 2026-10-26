import Foundation
import HighlightEngine

/// **Pure** deeper reads for an activity's dashboard (activity progress P4, prompt 181):
///
/// - `effort`: heart rate per set across sessions. For strength it compares sets at ONE reference load (the
///   weight you've done in the most sessions), so a falling line genuinely means the same work costs less —
///   "fitter". Without a repeated load, and for other disciplines, it's the average peak per set, shown
///   neutrally (lower could also mean easier work).
/// (The climbing overview's list of climbs is `LibraryCatalog.yours` — the same rows the Library shows.)
///
/// Uses `WorkoutHRStats.setEfforts` (the per-set HR windows session detail already shows), so the numbers agree.
enum ActivityInsights {

    struct EffortPoint: Identifiable, Equatable, Sendable {
        let sessionID: UUID
        let date: Date
        let bpm: Double
        var id: UUID { sessionID }
    }

    struct Effort: Equatable, Sendable {
        /// "Peak ♥ at 60 kg" or "Peak ♥ per set".
        let title: String
        /// The reference load in kg when the comparison is like-for-like.
        let referenceKg: Double?
        /// Oldest → newest; ≥ 2 points.
        let points: [EffortPoint]
        /// "set", or a racket match's "game" / "set" — for the caption.
        var unitNoun: String = "set"
        /// Last minus first, rounded bpm.
        var change: Int { Int((points.last!.bpm - points.first!.bpm).rounded()) }
        /// The same load now costs ≥ 3 bpm less — the only case worth calling "fitter".
        var fitter: Bool { referenceKg != nil && change <= -3 }
    }

    /// `nil` when fewer than two sessions have HR for this activity.
    static func effort(key: ActivityKey, history: [WorkoutSession], unit: WeightUnit,
                       identity: ActivityIdentity? = nil) -> Effort? {
        let identity = identity ?? ActivityIdentity(sessions: history)
        let sessions = history.filter { !$0.isActive && !$0.hrSeries.isEmpty }
            .sorted { $0.startedAt < $1.startedAt }

        // Per session: (weightKg?, peak bpm) for each completed set of the activity.
        var perSession: [(WorkoutSession, [(kg: Double?, bpm: Double)])] = []
        var racketUnit: RacketUnit?
        for s in sessions {
            let matching = s.exercises.filter { identity.matches(key, $0) }
            racketUnit = racketUnit ?? matching.first { $0.discipline == .racket }?.racketSport?.unit
            let ids = Set(matching.map(\.id))
            guard !ids.isEmpty else { continue }
            let hr = s.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm) }
            let efforts = WorkoutHRStats.setEfforts(for: s.exercises, sessionStart: s.startedAt, hr: hr,
                                                    maxHR: s.maxHR, restHR: s.restHR)
            var sets: [(kg: Double?, bpm: Double)] = []
            for ex in s.exercises where ids.contains(ex.id) {
                for (i, set) in ex.sets.enumerated() where set.completedAt != nil {
                    guard let peak = efforts[.init(exerciseID: ex.id, setIndex: i)]?.peakBpm else { continue }
                    let kg = set.actualWeight.flatMap { $0 > 0 ? WorkoutMath.toKg($0, set.weightUnit) : nil }
                    sets.append((kg.map(roundLoad), peak))
                }
            }
            if !sets.isEmpty { perSession.append((s, sets)) }
        }
        guard perSession.count >= 2 else { return nil }

        // A load done in ≥ 2 sessions → like-for-like; the most sessions wins (heavier on a tie).
        var sessionsPerLoad: [Double: Int] = [:]
        for (_, sets) in perSession { for kg in Set(sets.compactMap(\.kg)) { sessionsPerLoad[kg, default: 0] += 1 } }
        let reference = sessionsPerLoad.filter { $0.value >= 2 }
            .max { ($0.value, $0.key) < ($1.value, $1.key) }?.key

        let points: [EffortPoint] = perSession.compactMap { s, sets in
            let pool = reference.map { ref in sets.filter { $0.kg == ref } } ?? sets
            guard !pool.isEmpty else { return nil }
            return EffortPoint(sessionID: s.id, date: s.startedAt, bpm: pool.map(\.bpm).reduce(0, +) / Double(pool.count))
        }
        guard points.count >= 2 else { return nil }
        // A match is scored in games (tennis / padel: sets) — "per set" reads wrong on a table tennis match.
        let perUnit = "Peak ♥ per \(racketUnit?.noun ?? "set")"
        let title = reference.map { "Peak ♥ at \(ActivityDashboard.weightLabel(kg: $0, unit: unit))" } ?? perUnit
        return Effort(title: title, referenceKg: reference, points: points, unitNoun: racketUnit?.noun ?? "set")
    }

    /// Loads compare at 0.5 kg resolution so 60 and 60.0001 (a lb round-trip) are one load.
    static func roundLoad(_ kg: Double) -> Double { (kg * 2).rounded() / 2 }
}
