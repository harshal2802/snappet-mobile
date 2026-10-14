import Foundation
import HighlightEngine

/// **Pure** deeper reads for an activity's dashboard (activity progress P4, prompt 181):
///
/// - `effort`: heart rate per set across sessions. For strength it compares sets at ONE reference load (the
///   weight you've done in the most sessions), so a falling line genuinely means the same work costs less —
///   "fitter". Without a repeated load, and for other disciplines, it's the average peak per set, shown
///   neutrally (lower could also mean easier work).
/// - `climbs`: every named climb inside a discipline view — attempts, sends, sessions, clips — the "projects".
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
        /// Last minus first, rounded bpm.
        var change: Int { Int((points.last!.bpm - points.first!.bpm).rounded()) }
        /// The same load now costs ≥ 3 bpm less — the only case worth calling "fitter".
        var fitter: Bool { referenceKg != nil && change <= -3 }
    }

    /// `nil` when fewer than two sessions have HR for this activity.
    static func effort(key: ActivityKey, history: [WorkoutSession], unit: WeightUnit) -> Effort? {
        let sessions = history.filter { !$0.isActive && !$0.hrSeries.isEmpty }
            .sorted { $0.startedAt < $1.startedAt }

        // Per session: (weightKg?, peak bpm) for each completed set of the activity.
        var perSession: [(WorkoutSession, [(kg: Double?, bpm: Double)])] = []
        for s in sessions {
            let ids = Set(s.exercises.filter { key.matches($0) }.map(\.id))
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
        let title = reference.map { "Peak ♥ at \(ActivityDashboard.weightLabel(kg: $0, unit: unit))" } ?? "Peak ♥ per set"
        return Effort(title: title, referenceKg: reference, points: points)
    }

    /// Loads compare at 0.5 kg resolution so 60 and 60.0001 (a lb round-trip) are one load.
    static func roundLoad(_ kg: Double) -> Double { (kg * 2).rounded() / 2 }

    // MARK: - Climbs inside a discipline view

    struct ClimbSummary: Identifiable, Equatable, Sendable {
        let key: ActivityKey
        let name: String
        let grade: String?
        let sessions: Int
        let attempts: Int
        let sent: Bool
        let lastDate: Date
        let clipCount: Int
        var id: ActivityKey { key }
    }

    /// Every NAMED climb in history (unnamed climbs have no identity to drill into), most recent first.
    static func climbs(history: [WorkoutSession], media: [ActivityMediaInput]) -> [ClimbSummary] {
        struct Acc { var name: String; var grade: String?; var sessions = Set<UUID>(); var attempts = 0
                     var sent = false; var last = Date.distantPast; var entityIDs = Set<UUID>() }
        var acc: [ActivityKey: Acc] = [:]
        for s in history where !s.isActive {
            for ex in s.exercises where ex.discipline == .climb {
                guard let key = ActivityKey.of(ex), !key.nameKey.isEmpty,
                      let name = ex.displayName, !name.isEmpty else { continue }
                var a = acc[key] ?? Acc(name: name, grade: ex.climbGradeLabel)
                a.sessions.insert(s.id)
                let done = ex.sets.filter { $0.completedAt != nil }
                a.attempts += done.reduce(0) { $0 + max(1, $1.climbAttempts ?? 1) }
                a.sent = a.sent || done.contains(where: SetMeasure.isSend)
                if s.startedAt > a.last { a.last = s.startedAt; a.grade = ex.climbGradeLabel ?? a.grade }
                a.entityIDs.insert(ex.id)
                acc[key] = a
            }
        }
        return acc.map { key, a in
            ClimbSummary(key: key, name: a.name, grade: a.grade, sessions: a.sessions.count, attempts: a.attempts,
                         sent: a.sent, lastDate: a.last,
                         clipCount: media.filter { !$0.isReel && $0.assignedExerciseID.map(a.entityIDs.contains) == true }.count)
        }
        .sorted { $0.lastDate > $1.lastDate }
    }
}
