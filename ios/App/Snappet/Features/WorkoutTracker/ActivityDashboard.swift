import Foundation

/// **Pure** per-activity dashboard (activity progress P2, prompt 179): one activity's history → a hero metric
/// over time, KPI tiles, records (each tied to the session it was set in, so the view can play that session's
/// clip), and an 18-week frequency strip. The hero metric adapts to the discipline:
///
/// | discipline | hero (per session)                         | better |
/// |------------|--------------------------------------------|--------|
/// | strength   | est. 1RM of the best set (Epley); bodyweight → max reps | higher |
/// | climb      | hardest SENT grade (scale difficulty)      | higher |
/// | timed      | longest hold                               | higher |
/// | run        | average pace                               | lower  |
/// | dance/other| total time                                 | higher |
///
/// Foundation only — no SwiftData / Charts / UI — so it runs in `SnappetTests`.
struct ActivityDashboard: Equatable, Sendable {

    enum Metric: String, Sendable, Equatable {
        case oneRepMax, maxReps, hardestSend, longestHold, pace, totalTime

        var title: String {
            switch self {
            case .oneRepMax: return "Est. 1RM"
            case .maxReps: return "Max reps"
            case .hardestSend: return "Hardest send"
            case .longestHold: return "Longest hold"
            case .pace: return "Pace"
            case .totalTime: return "Time"
            }
        }
        var higherIsBetter: Bool { self != .pace }
    }

    struct Point: Identifiable, Equatable, Sendable {
        let sessionID: UUID
        let date: Date
        /// The metric in its canonical unit (kg · reps · grade difficulty · seconds · sec/km).
        let value: Double
        /// The value as shown ("81 kg", "V5", "1:03", "5:42 /km").
        let label: String
        /// The session has at least one clip of this activity — the chart's 📷 marker.
        let hasMedia: Bool
        var id: UUID { sessionID }
    }

    struct KPI: Equatable, Sendable {
        let title: String
        let value: String
        /// A short trend line ("▲ 31%", "2×/wk", "today") — `nil` when there's nothing honest to say.
        let detail: String?
        let improving: Bool
    }

    struct Record: Identifiable, Equatable, Sendable {
        let title: String
        let value: String
        let sessionID: UUID
        let date: Date
        var id: String { title }
    }

    let key: ActivityKey
    let discipline: WorkoutDiscipline
    let metric: Metric
    /// Oldest → newest.
    let points: [Point]
    let kpis: [KPI]
    let records: [Record]
    /// Sessions per week, oldest → newest; the last entry is the current week.
    let weeks: [Int]
    let sessionCount: Int
    let lastDone: Date?

    static let weekCount = 18

    // MARK: - Build

    /// `nil` when the activity was never done in a completed session.
    static func make(key: ActivityKey, history: [WorkoutSession], media: [ActivityMediaInput],
                     unit: WeightUnit, now: Date = .now, calendar: Calendar = .current) -> ActivityDashboard? {
        var sessions: [(WorkoutSession, [SessionExercise])] = []
        for s in history where !s.isActive {
            let ents = s.exercises.filter { ex in
                ActivityKey.of(ex) == key && ex.sets.contains { $0.completedAt != nil }
            }
            if !ents.isEmpty { sessions.append((s, ents)) }
        }
        sessions.sort { $0.0.startedAt < $1.0.startedAt }
        guard let first = sessions.first else { return nil }
        let discipline = first.1[0].discipline
        let distanceUnit: DistanceUnit = unit == .lb ? .mi : .km

        // Which sessions hold a clip of this activity.
        let entityIDs = Set(sessions.flatMap { $0.1.map(\.id) })
        let mediaSessions = Set(media.filter { !$0.isReel && $0.assignedExerciseID.map(entityIDs.contains) == true }
            .map(\.sessionID))

        let metric = chooseMetric(discipline: discipline, entities: sessions.flatMap(\.1))
        let points: [Point] = sessions.compactMap { s, ents in
            guard let v = value(metric, ents) else { return nil }
            return Point(sessionID: s.id, date: s.startedAt, value: v,
                         label: format(metric, v, unit: unit, distanceUnit: distanceUnit, scaleFrom: ents),
                         hasMedia: mediaSessions.contains(s.id))
        }

        let lastDone = sessions.last?.0.startedAt
        let weeks = weekCounts(dates: sessions.map(\.0.startedAt), now: now, calendar: calendar)
        let kpis = makeKPIs(metric: metric, points: points, sessionCount: sessions.count, weeks: weeks,
                            lastDone: lastDone, now: now, calendar: calendar)
        let records = makeRecords(discipline: discipline, metric: metric, sessions: sessions, points: points,
                                  unit: unit, distanceUnit: distanceUnit)
        return ActivityDashboard(key: key, discipline: discipline, metric: metric, points: points, kpis: kpis,
                                 records: records, weeks: weeks, sessionCount: sessions.count, lastDone: lastDone)
    }

    // MARK: - Metric

    static func chooseMetric(discipline: WorkoutDiscipline, entities: [SessionExercise]) -> Metric {
        switch discipline {
        case .strength:
            let weighted = entities.contains { $0.sets.contains { $0.completedAt != nil && ($0.actualWeight ?? 0) > 0 } }
            return weighted ? .oneRepMax : .maxReps
        case .climb: return .hardestSend
        case .run: return .pace
        case .timed: return .longestHold
        case .dance, .other: return .totalTime
        }
    }

    /// Epley: w × (1 + reps / 30); a single is the weight itself.
    static func oneRepMax(kg: Double, reps: Int) -> Double {
        reps <= 1 ? kg : kg * (1 + Double(reps) / 30)
    }

    static func value(_ metric: Metric, _ ents: [SessionExercise]) -> Double? {
        let done = ents.flatMap { ex in ex.sets.filter { $0.completedAt != nil }.map { (ex, $0) } }
        switch metric {
        case .oneRepMax:
            return done.compactMap { _, s -> Double? in
                guard let w = s.actualWeight, w > 0, let r = s.actualReps, r > 0 else { return nil }
                return oneRepMax(kg: WorkoutMath.toKg(w, s.weightUnit), reps: r)
            }.max()
        case .maxReps:
            return done.compactMap { $0.1.actualReps }.filter { $0 > 0 }.max().map(Double.init)
        case .hardestSend:
            return done.compactMap { ex, s -> Double? in
                guard SetMeasure.isSend(s), let g = s.climbGradeLabel ?? ex.climbGradeLabel else { return nil }
                return ex.climbGradeScale.difficulty(for: g)
            }.max()
        case .longestHold:
            return done.compactMap(\.1.durationSec).filter { $0 > 0 }.max()
        case .pace:
            let paces = ents.compactMap(RunStats.avgPaceSecPerKm)
            return paces.min()
        case .totalTime:
            let t = done.compactMap(\.1.durationSec).reduce(0, +)
            return t > 0 ? t : nil
        }
    }

    static func format(_ metric: Metric, _ v: Double, unit: WeightUnit, distanceUnit: DistanceUnit,
                       scaleFrom ents: [SessionExercise] = []) -> String {
        switch metric {
        case .oneRepMax: return "\(WorkoutMath.formatWeight(kg: v, unit: unit)) \(unit.display)"
        case .maxReps: return "\(Int(v)) reps"
        case .hardestSend:
            // Map the difficulty back to the label it came from.
            for ex in ents {
                for s in ex.sets {
                    if let g = s.climbGradeLabel ?? ex.climbGradeLabel, ex.climbGradeScale.difficulty(for: g) == v { return g }
                }
            }
            return String(format: "%.0f", v)
        case .longestHold, .totalTime: return SetMeasure.formatDuration(v)
        case .pace: return SetMeasure.formatPace(secPerKm: v, unit: distanceUnit)
        }
    }

    /// A logged weight as typed: "67.5 kg" stays 67.5 in its own unit (prompt 146's rule), whole numbers
    /// after a kg↔lb conversion.
    static func weightLabel(kg: Double, unit: WeightUnit) -> String {
        let shown = unit == .kg ? SetMeasure.formatWeight((kg * 100).rounded() / 100)
                                : WorkoutMath.formatWeight(kg: kg, unit: unit)
        return "\(shown) \(unit.display)"
    }

    // MARK: - KPIs / records / frequency

    private static func makeKPIs(metric: Metric, points: [Point], sessionCount: Int, weeks: [Int],
                                 lastDone: Date?, now: Date, calendar: Calendar) -> [KPI] {
        var out: [KPI] = []
        if let best = bestPoint(metric, points), let firstValue = points.first?.value {
            let change = firstValue != 0 ? (best.value - firstValue) / firstValue : 0
            let improved = metric.higherIsBetter ? change > 0.0001 : change < -0.0001
            let pct = Int((abs(change) * 100).rounded())
            out.append(KPI(title: metric == .pace ? "Best pace" : metric.title, value: best.label,
                           detail: improved && pct > 0 ? "▲ \(pct)%" : nil, improving: improved))
        }
        // Frequency over the last 8 weeks.
        let recent = weeks.suffix(8).reduce(0, +)
        let perWeek = Double(recent) / 8
        out.append(KPI(title: "Sessions", value: "\(sessionCount)",
                       detail: perWeek >= 0.5 ? "\(perWeek.formatted(.number.precision(.fractionLength(0...1))))×/wk" : nil,
                       improving: false))
        if let lastDone {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastDone),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            let value = days == 0 ? "Today" : days == 1 ? "Yesterday" : "\(days)d ago"
            let streak = trailingStreak(weeks)
            out.append(KPI(title: "Last done", value: value,
                           detail: streak >= 2 ? "🔥 \(streak) wk" : nil, improving: false))
        }
        return out
    }

    /// The best point by the metric's direction (earliest wins a tie — that's when the record was SET).
    static func bestPoint(_ metric: Metric, _ points: [Point]) -> Point? {
        points.reduce(nil) { best, p in
            guard let best else { return p }
            return (metric.higherIsBetter ? p.value > best.value : p.value < best.value) ? p : best
        }
    }

    private static func makeRecords(discipline: WorkoutDiscipline, metric: Metric,
                                    sessions: [(WorkoutSession, [SessionExercise])], points: [Point],
                                    unit: WeightUnit, distanceUnit: DistanceUnit) -> [Record] {
        var out: [Record] = []
        if let best = bestPoint(metric, points) {
            out.append(Record(title: metric == .pace ? "Best pace" : metric.title, value: best.label,
                              sessionID: best.sessionID, date: best.date))
        }
        switch discipline {
        case .strength:
            // Best set (weight × reps) and best session volume.
            var bestSet: (score: Double, label: String, s: WorkoutSession)?
            var bestVol: (kg: Double, s: WorkoutSession)?
            for (s, ents) in sessions {
                var vol = 0.0
                for ex in ents {
                    for set in ex.sets where set.completedAt != nil {
                        guard let r = set.actualReps, r > 0 else { continue }
                        let kg = set.actualWeight.map { WorkoutMath.toKg($0, set.weightUnit) } ?? 0
                        vol += kg * Double(r)
                        let score = max(kg, 1) * Double(r)
                        if score > (bestSet?.score ?? 0) {
                            let label = kg > 0 ? "\(weightLabel(kg: kg, unit: unit)) × \(r)"
                                               : "\(r) reps"
                            bestSet = (score, label, s)
                        }
                    }
                }
                if vol > (bestVol?.kg ?? 0) { bestVol = (vol, s) }
            }
            if let b = bestSet { out.append(Record(title: "Best set", value: b.label, sessionID: b.s.id, date: b.s.startedAt)) }
            if let v = bestVol {
                out.append(Record(title: "Best volume", value: WorkoutMath.formatVolume(kg: v.kg, unit: unit),
                                  sessionID: v.s.id, date: v.s.startedAt))
            }
        case .climb:
            if let firstSend = sessions.first(where: { $0.1.contains { $0.sets.contains(where: SetMeasure.isSend) } }) {
                out.append(Record(title: "First send", value: firstSend.0.routineName,
                                  sessionID: firstSend.0.id, date: firstSend.0.startedAt))
            }
        case .run:
            func meters(_ ents: [SessionExercise]) -> Double { ents.reduce(0) { $0 + RunStats.totalDistanceMeters($1) } }
            if let l = sessions.max(by: { meters($0.1) < meters($1.1) }), meters(l.1) > 0 {
                out.append(Record(title: "Longest", value: SetMeasure.formatDistance(meters(l.1), unit: distanceUnit),
                                  sessionID: l.0.id, date: l.0.startedAt))
            }
        case .timed:
            var heaviest: (kg: Double, s: WorkoutSession)?
            for (s, ents) in sessions {
                for set in ents.flatMap(\.sets) where set.completedAt != nil {
                    if let l = set.loadKg, l > (heaviest?.kg ?? 0) { heaviest = (l, s) }
                }
            }
            if let h = heaviest {
                out.append(Record(title: "Heaviest load", value: "+\(SetMeasure.formatWeight(h.kg)) kg",
                                  sessionID: h.s.id, date: h.s.startedAt))
            }
        case .dance, .other: break
        }
        if let f = sessions.first, let p = points.first {
            out.append(Record(title: "First session", value: p.label, sessionID: f.0.id, date: f.0.startedAt))
        }
        // Distinct titles only (the hero record and a discipline record can coincide, e.g. "Hardest send").
        var seen = Set<String>()
        return out.filter { seen.insert($0.title).inserted }
    }

    /// Sessions per calendar week for the last `weekCount` weeks, oldest → newest.
    static func weekCounts(dates: [Date], now: Date, calendar: Calendar) -> [Int] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var out = Array(repeating: 0, count: weekCount)
        for d in dates {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: d)?.start,
                  let weeksAgo = calendar.dateComponents([.weekOfYear], from: start, to: thisWeek).weekOfYear,
                  weeksAgo >= 0, weeksAgo < weekCount else { continue }
            out[weekCount - 1 - weeksAgo] += 1
        }
        return out
    }

    /// Consecutive weeks with ≥ 1 session, ending this week (or last week, if this one is still empty).
    static func trailingStreak(_ weeks: [Int]) -> Int {
        var list = weeks
        if list.last == 0 { list.removeLast() }
        var n = 0
        for c in list.reversed() { if c > 0 { n += 1 } else { break } }
        return n
    }
}
