import Foundation

/// The history behind a session (prompt 146, wireframe `docs/ux-research/session-detail/`): what changed
/// since last time, the records it set, the routine's trend and the next milestone — per workout type.
/// Pure (Foundation + model value reads) so every number on the redesigned session detail is unit-tested.
/// The future progression/XP system reads the same insights (badges become XP bonuses).
enum SessionInsights {

    // MARK: - What it's compared with

    /// Earlier completed sessions to compare with, newest first: the same routine; for a quick session
    /// (no routine), past sessions with the same name and the same main workout type.
    static func comparable(for session: WorkoutSession, in all: [WorkoutSession]) -> [WorkoutSession] {
        let kind = Kind.of(session)
        return all.filter { other in
            other.id != session.id && other.completedAt != nil && other.startedAt < session.startedAt
                && !other.isImportedFromHealth
                && (session.routineID.map { other.routineID == $0 }
                    ?? (other.routineID == nil && other.routineName == session.routineName && Kind.of(other) == kind))
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// "8th" — this session's place in its series.
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// Consecutive calendar weeks, ending with this session's week, that have at least one session of
    /// the series (this one included).
    static func weekStreak(_ session: WorkoutSession, prior: [WorkoutSession], calendar: Calendar = .current) -> Int {
        func week(_ d: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d }
        let weeks = Set((prior.map(\.startedAt) + [session.startedAt]).map(week))
        var cursor = week(session.startedAt)
        var count = 0
        while weeks.contains(cursor) {
            count += 1
            guard let prev = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = week(prev)
        }
        return count
    }

    /// Whether the session fell on a planned day of its routine's schedule (nil when unscheduled).
    static func onPlan(_ session: WorkoutSession, schedule: RoutineSchedule?, calendar: Calendar = .current) -> Bool? {
        guard let schedule, schedule.isEnabled else { return nil }
        return schedule.occurs(on: DayKey(session.startedAt, calendar: calendar), calendar: calendar)
    }

    // MARK: - Workout type

    enum Kind: Equatable, Sendable {
        case strength, hangboard, timed, climb, run, other

        static func of(_ s: WorkoutSession) -> Kind {
            let ex = s.exercises.filter { $0.completedSetCount > 0 }
            guard !ex.isEmpty else { return .other }
            let counts = Dictionary(grouping: ex, by: \.discipline).mapValues(\.count)
            let top = counts.max { $0.value < $1.value }?.key ?? .other
            switch top {
            case .strength: return .strength
            case .climb: return .climb
            case .run: return .run
            case .timed:
                let isHang = ex.contains { $0.timedCategory == "hangboard" || $0.sets.contains { $0.loadKg != nil || $0.forceReps != nil } }
                return isHang ? .hangboard : .timed
            case .dance, .other: return .other
            }
        }
    }

    // MARK: - Headline stats with change since last time

    struct Stat: Equatable, Sendable {
        var value: Double
        var display: String
        var label: String
        /// Pace, tries per send, heart rate on the same run: lower is better.
        var lowerIsBetter = false
        /// When false the stat isn't compared (nothing comparable).
        var comparable = true
    }

    struct Change: Equatable, Sendable {
        enum Direction { case better, worse, same }
        var text: String
        var direction: Direction
    }

    /// The three headline stats for the session's type.
    static func headline(_ s: WorkoutSession, unit: WeightUnit) -> [Stat] {
        switch Kind.of(s) {
        case .strength:
            let vol = volumeKg(s)
            let reps = totalReps(s, weightedOnly: false)
            let top = topSet(s)
            let volStat = vol > 0
                ? Stat(value: vol, display: groupedWeight(vol, unit), label: "\(unit.display) volume")
                : Stat(value: Double(reps), display: "\(reps)", label: "reps")
            let topStat = top.map {
                Stat(value: $0.kg, display: "\(SetMeasure.formatWeight(round1(WorkoutMath.kgToUnit($0.kg, unit))))×\($0.reps)",
                     label: "top set")
            } ?? Stat(value: Double(maxReps(s)), display: "\(maxReps(s))", label: "best set reps")
            return [volStat, topStat, Stat(value: Double(completedSets(s)), display: "\(completedSets(s))", label: "sets")]
        case .hangboard:
            let load = maxLoadKg(s)
            let peak = peakForce(s)
            let hangs = forceRepCount(s)
            var out: [Stat] = [
                Stat(value: load ?? 0, display: load.map(signedLoad) ?? "BW", label: load == nil ? "bodyweight" : "kg added"),
            ]
            if let peak {
                out.append(Stat(value: peak, display: SetMeasure.formatWeight(round1(peak)), label: "kg peak force"))
            } else {
                out.append(Stat(value: holdTime(s), display: SetMeasure.formatDuration(holdTime(s)), label: "time under load"))
            }
            if let planned = plannedHangs(s), hangs > 0 {
                out.append(Stat(value: Double(hangs), display: "\(hangs)/\(planned)", label: "hangs", comparable: false))
            } else {
                out.append(Stat(value: Double(completedSets(s)), display: "\(completedSets(s))", label: "runs"))
            }
            return out
        case .timed:
            let best = bestHold(s)
            return [Stat(value: holdTime(s), display: SetMeasure.formatDuration(holdTime(s)), label: "hold time"),
                    Stat(value: best, display: best > 0 ? SetMeasure.formatDuration(best) : "—", label: "best hold"),
                    Stat(value: Double(completedSets(s)), display: "\(completedSets(s))", label: "sets")]
        case .climb:
            let c = climbs(s)
            let tries = c.sends > 0 ? Double(c.attempts) / Double(c.sends) : 0
            return [Stat(value: Double(c.sends), display: "\(c.sends)", label: "sends"),
                    Stat(value: c.hardestDifficulty ?? -1, display: c.hardest ?? "—", label: "hardest"),
                    Stat(value: tries, display: tries > 0 ? String(format: "%.1f", tries) : "—", label: "tries / send",
                         lowerIsBetter: true, comparable: tries > 0)]
        case .run:
            let r = runTotals(s)
            let du: DistanceUnit = unit == .lb ? .mi : .km
            let pace = r.meters > 0 ? r.seconds / (r.meters / 1000) : 0
            var out = [Stat(value: r.meters, display: SetMeasure.formatDistance(r.meters, unit: du), label: "distance"),
                       Stat(value: pace, display: pace > 0 ? SetMeasure.formatPace(secPerKm: pace, unit: du) : "—",
                            label: "pace", lowerIsBetter: true, comparable: pace > 0)]
            if let hr = avgHR(s) {
                out.append(Stat(value: hr, display: "\(Int(hr.rounded()))", label: "avg bpm", lowerIsBetter: true))
            } else {
                out.append(Stat(value: s.duration, display: SetMeasure.formatDuration(s.duration), label: "duration"))
            }
            return out
        case .other:
            return [Stat(value: s.duration, display: SetMeasure.formatDuration(s.duration), label: "duration"),
                    Stat(value: Double(completedSets(s)), display: "\(completedSets(s))", label: "efforts"),
                    Stat(value: avgHR(s) ?? 0, display: avgHR(s).map { "\(Int($0.rounded()))" } ?? "—", label: "avg bpm",
                         comparable: false)]
        }
    }

    /// "▲ 6% vs last", "▼ 9 s faster", "= last" — nil when there's nothing to compare.
    static func change(_ now: Stat, last: Stat?, kind: Kind) -> Change? {
        guard now.comparable, let last, last.comparable, last.label == now.label else { return nil }
        let diff = now.value - last.value
        if abs(diff) < 0.0001 { return Change(text: "= last", direction: .same) }
        let better = now.lowerIsBetter ? diff < 0 : diff > 0
        let arrow = diff > 0 ? "▲" : "▼"
        let text: String
        switch now.label {
        case "pace":
            text = "\(arrow) \(Int(abs(diff).rounded())) s \(diff < 0 ? "faster" : "slower")"
        case "hardest":
            text = diff > 0 ? "▲ new high" : "▼ easier"
        case "kg added", "kg peak force":
            text = "\(arrow) \(diff > 0 ? "+" : "−")\(SetMeasure.formatWeight(round2(abs(diff))))"
        case "top set":
            text = "\(arrow) \(diff > 0 ? "+" : "−")\(SetMeasure.formatWeight(round2(abs(diff)))) kg"
        case "sets", "sends", "runs", "efforts", "reps", "best set reps":
            text = "\(arrow) \(diff > 0 ? "+" : "−")\(Int(abs(diff).rounded()))"
        case "tries / send", "avg bpm":
            text = "\(arrow) \(diff < 0 ? "better" : "harder")"
        default:
            let pct = last.value != 0 ? abs(diff) / abs(last.value) * 100 : 0
            text = pct >= 1 ? "\(arrow) \(Int(pct.rounded()))% vs last" : "\(arrow) vs last"
        }
        return Change(text: text, direction: better ? .better : .worse)
    }

    // MARK: - Badges (records, firsts, streaks, milestones — all real)

    enum Badge: Equatable, Sendable, Identifiable {
        case firstOfSeries(name: String)
        case weightPR(exercise: String, kg: Double, reps: Int, previousKg: Double?)
        case repPR(exercise: String, reps: Int)
        case bestVolume(name: String)
        case heaviestLoad(kg: Double)
        case peakForcePR(kg: Double)
        case firstSend(grade: String)
        case mostSends(count: Int)
        case fastestPace(display: String)
        case longestDistance(display: String)
        case sessionCount(n: Int, name: String)
        case weekStreak(weeks: Int)

        var id: String { "\(self)" }
    }

    static let countMilestones = [5, 10, 25, 50, 100, 150, 200, 250, 365, 500, 750, 1000]

    static func badges(_ s: WorkoutSession, prior: [WorkoutSession], allHistory: [WorkoutSession],
                       resolve: (SessionExercise) -> String, unit: WeightUnit) -> [Badge] {
        var out: [Badge] = []
        let kind = Kind.of(s)
        let n = prior.count + 1
        if prior.isEmpty { out.append(.firstOfSeries(name: s.routineName)) }
        let earlier = allHistory.filter { $0.id != s.id && $0.startedAt < s.startedAt && !$0.isImportedFromHealth }

        switch kind {
        case .strength:
            // Weighted PRs across ALL history for that exercise (a PR is a PR wherever it was set).
            var seen = Set<String>()
            for ex in s.exercises where ex.kind == .repsWeight && seen.insert(ex.exerciseId).inserted {
                guard let best = WorkoutMath.topWeightedSet(history: [s], exerciseId: ex.exerciseId) else {
                    // Bodyweight: rep PR on the total reps for the exercise.
                    let reps = ex.sets.filter { $0.completedAt != nil }.compactMap(\.actualReps).reduce(0, +)
                    let priorBest = earlier.compactMap { p in
                        p.exercises.filter { $0.exerciseId == ex.exerciseId }
                            .flatMap { $0.sets.filter { $0.completedAt != nil } }.compactMap(\.actualReps).reduce(0, +)
                    }.max() ?? 0
                    if priorBest > 0, reps > priorBest { out.append(.repPR(exercise: resolve(ex), reps: reps)) }
                    continue
                }
                let previous = WorkoutMath.topWeightedSet(history: earlier, exerciseId: ex.exerciseId)
                let score = best.bestKg * Double(best.bestReps)
                let prevScore = previous.map { $0.bestKg * Double($0.bestReps) } ?? 0
                if previous != nil, score > prevScore {
                    out.append(.weightPR(exercise: resolve(ex), kg: best.bestKg, reps: best.bestReps, previousKg: previous?.bestKg))
                }
            }
            let vol = volumeKg(s)
            if !prior.isEmpty, vol > 0, vol > (prior.map(volumeKg).max() ?? 0) { out.append(.bestVolume(name: s.routineName)) }
        case .hangboard:
            if let load = maxLoadKg(s), !prior.isEmpty, load > (prior.compactMap(maxLoadKg).max() ?? -.infinity) {
                out.append(.heaviestLoad(kg: load))
            }
            if let peak = peakForce(s), let prev = prior.compactMap(peakForce).max(), peak > prev {
                out.append(.peakForcePR(kg: peak))
            }
        case .climb:
            for m in FreeformSummary.milestones(for: s, history: earlier) {
                if case .firstSend(let g) = m { out.append(.firstSend(grade: g)) }
            }
            let sends = climbs(s).sends
            if !prior.isEmpty, sends > 0, sends > (prior.map { climbs($0).sends }.max() ?? 0) { out.append(.mostSends(count: sends)) }
        case .run:
            let r = runTotals(s)
            if r.meters > 0, r.seconds > 0, !prior.isEmpty {
                let pace = r.seconds / (r.meters / 1000)
                let similar = prior.map(runTotals).filter { $0.meters > 0 && abs($0.meters - r.meters) / r.meters <= 0.2 }
                if !similar.isEmpty, pace < (similar.map { $0.seconds / ($0.meters / 1000) }.min() ?? .infinity) {
                    out.append(.fastestPace(display: SetMeasure.formatPace(secPerKm: pace, unit: unit == .lb ? .mi : .km)))
                }
                if r.meters > (prior.map { runTotals($0).meters }.max() ?? 0) {
                    out.append(.longestDistance(display: SetMeasure.formatDistance(r.meters, unit: unit == .lb ? .mi : .km)))
                }
            }
        case .timed, .other:
            break
        }
        if countMilestones.contains(n), n > 1 { out.append(.sessionCount(n: n, name: s.routineName)) }
        let streak = weekStreak(s, prior: prior)
        if streak >= 2 { out.append(.weekStreak(weeks: streak)) }
        return out
    }

    /// The next count milestone for the series and how far along it is.
    static func nextMilestone(count n: Int) -> (target: Int, previous: Int) {
        let target = countMilestones.first { $0 > n } ?? ((n / 1000) + 1) * 1000
        let previous = countMilestones.last { $0 <= n } ?? 0
        return (target, previous)
    }

    // MARK: - Progress over time

    struct Progress: Equatable {
        var title: String
        /// Oldest → newest; the last point is this session.
        var points: [Double]
        var best: Double
        var lowerIsBetter: Bool
        var display: (Double) -> String

        static func == (a: Progress, b: Progress) -> Bool {
            a.title == b.title && a.points == b.points && a.best == b.best && a.lowerIsBetter == b.lowerIsBetter
        }
    }

    /// The routine's trend for its type over the last `limit` sessions (needs at least 2 points).
    static func progress(_ s: WorkoutSession, prior: [WorkoutSession], unit: WeightUnit, limit: Int = 8) -> Progress? {
        let series = (prior.prefix(limit - 1).reversed() + [s])
        func make(_ title: String, _ v: (WorkoutSession) -> Double?, lower: Bool = false,
                  _ display: @escaping (Double) -> String) -> Progress? {
            let pts = series.compactMap(v)
            guard pts.count >= 2 else { return nil }
            return Progress(title: title, points: pts, best: lower ? (pts.min() ?? 0) : (pts.max() ?? 0),
                            lowerIsBetter: lower, display: display)
        }
        switch Kind.of(s) {
        case .strength:
            return make("Volume", { volumeKg($0) > 0 ? volumeKg($0) : nil }) { "\(groupedWeight($0, unit)) \(unit.display)" }
                ?? make("Reps", { Double(totalReps($0, weightedOnly: false)) }) { "\(Int($0)) reps" }
        case .hangboard:
            return make("Added load", { maxLoadKg($0) }) { signedLoad($0) + " kg" }
                ?? make("Peak force", { peakForce($0) }) { "\(SetMeasure.formatWeight(round1($0))) kg" }
        case .timed:
            return make("Hold time", { holdTime($0) > 0 ? holdTime($0) : nil }) { SetMeasure.formatDuration($0) }
        case .climb:
            return make("Sends", { Double(climbs($0).sends) }) { "\(Int($0)) sends" }
        case .run:
            return make("Pace", { r in
                let t = runTotals(r); return t.meters > 0 ? t.seconds / (t.meters / 1000) : nil
            }, lower: true) { SetMeasure.formatPace(secPerKm: $0, unit: unit == .lb ? .mi : .km) }
        case .other:
            return nil
        }
    }

    // MARK: - Exercises compare themselves (strength)

    struct ExerciseCompare: Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        var summary: String
        var change: Change?
        /// Top weight per session, oldest → newest (this one last); empty for bodyweight.
        var trend: [Double]
        /// Per-set change vs the same set last time ("+2.5 kg", "−1 rep", "=").
        var setChanges: [String]
        /// "Held for 3 sessions — try +2.5 next time".
        var nudge: String?
    }

    static func exerciseCompares(_ s: WorkoutSession, history: [WorkoutSession], unit: WeightUnit,
                                 resolve: (SessionExercise) -> String, step: Double = 2.5) -> [ExerciseCompare] {
        let earlier = history.filter { $0.id != s.id && $0.startedAt < s.startedAt }.sorted { $0.startedAt > $1.startedAt }
        return s.exercises.filter { $0.kind == .repsWeight && $0.completedSetCount > 0 }.map { ex in
            let done = ex.sets.filter { $0.completedAt != nil }
            let lastEx = earlier.lazy.compactMap { p in p.exercises.first { $0.exerciseId == ex.exerciseId && $0.completedSetCount > 0 } }.first
            let lastSets = lastEx?.sets.filter { $0.completedAt != nil } ?? []
            func kg(_ set: SetLog) -> Double { WorkoutMath.toKg(set.actualWeight ?? 0, set.weightUnit) }
            let weighted = done.contains { ($0.actualWeight ?? 0) > 0 }
            let topKg = done.map(kg).max() ?? 0
            let reps = done.compactMap(\.actualReps)
            let summary: String
            if weighted {
                let w = SetMeasure.formatWeight(round1(WorkoutMath.kgToUnit(topKg, unit)))
                var s = "\(done.count) × \(reps.max() ?? 0) @ \(w) \(unit.display)"
                if let e = StrengthStats.estimatedOneRepMax(ex) {
                    s += " · est. 1RM \(Int(WorkoutMath.kgToUnit(WorkoutMath.toKg(e.value, e.unit), unit).rounded())) \(unit.display)"
                }
                summary = s
            } else {
                summary = "\(done.count) × \(reps.max() ?? 0) · bodyweight · \(reps.reduce(0, +)) reps total"
            }
            var change: Change?
            if !lastSets.isEmpty {
                if weighted {
                    let lastTop = lastSets.map(kg).max() ?? 0
                    let d = topKg - lastTop
                    change = abs(d) < 0.01 ? Change(text: "= last", direction: .same)
                        : Change(text: "\(d > 0 ? "▲ +" : "▼ −")\(SetMeasure.formatWeight(round2(abs(WorkoutMath.kgToUnit(d, unit))))) \(unit.display)",
                                 direction: d > 0 ? .better : .worse)
                } else {
                    let d = reps.reduce(0, +) - lastSets.compactMap(\.actualReps).reduce(0, +)
                    change = d == 0 ? Change(text: "= last", direction: .same)
                        : Change(text: "\(d > 0 ? "▲ +" : "▼ −")\(abs(d)) reps", direction: d > 0 ? .better : .worse)
                }
            }
            let setChanges: [String] = done.enumerated().map { i, set in
                guard i < lastSets.count else { return "new" }
                let prev = lastSets[i]
                let dw = kg(set) - kg(prev)
                let dr = (set.actualReps ?? 0) - (prev.actualReps ?? 0)
                if weighted, abs(dw) >= 0.01 {
                    return "\(dw > 0 ? "+" : "−")\(SetMeasure.formatWeight(round2(abs(WorkoutMath.kgToUnit(dw, unit))))) \(unit.display)"
                }
                if dr != 0 { return "\(dr > 0 ? "+" : "−")\(abs(dr)) rep\(abs(dr) == 1 ? "" : "s")" }
                return "="
            }
            let tops: [Double] = weighted
                ? (earlier.prefix(7).reversed().compactMap { p in
                    p.exercises.first { $0.exerciseId == ex.exerciseId }.map { $0.sets.filter { $0.completedAt != nil }.map(kg).max() ?? 0 }
                  }.filter { $0 > 0 } + [topKg])
                : []
            // Same top weight for the last 3 sessions (this one included) → suggest the next step.
            var nudge: String?
            if weighted, tops.count >= 3, tops.suffix(3).allSatisfy({ abs($0 - topKg) < 0.01 }) {
                nudge = "Held for 3 sessions — try +\(SetMeasure.formatWeight(step)) \(unit.display) next time"
            }
            return ExerciseCompare(id: ex.id, name: resolve(ex), summary: summary, change: change,
                                   trend: tops, setChanges: setChanges, nudge: nudge)
        }
    }

    // MARK: - Hangboard force grid

    struct ForceGrid: Equatable, Sendable {
        /// rows = sets, columns = reps (peak kg); nil where nothing was measured.
        var cells: [[Double?]]
        /// Drop from the first set's mean peak to the last set's, as a fraction (0.03 = 3 %).
        var fatigue: Double?
    }

    static func forceGrid(_ s: WorkoutSession) -> ForceGrid? {
        let reps = s.exercises.flatMap { $0.sets.flatMap { $0.forceReps ?? [] } }
        guard !reps.isEmpty else { return nil }
        let sets = reps.map(\.set).max() ?? 1
        let perSet = reps.map(\.rep).max() ?? 1
        var cells = Array(repeating: [Double?](repeating: nil, count: perSet), count: sets)
        for r in reps where r.set >= 1 && r.rep >= 1 {
            let current = cells[r.set - 1][r.rep - 1] ?? 0
            cells[r.set - 1][r.rep - 1] = max(current, r.peakKg)
        }
        func mean(_ row: [Double?]) -> Double? {
            let v = row.compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        var fatigue: Double?
        if sets > 1, let first = cells.first.flatMap(mean), let last = cells.last.flatMap(mean), first > 0 {
            fatigue = (first - last) / first
        }
        return ForceGrid(cells: cells, fatigue: fatigue)
    }

    // MARK: - Climbing pyramid vs the last 30 days

    struct PyramidRow: Equatable, Sendable {
        var grade: String
        var today: Int
        var last30: Int
    }

    static func pyramid(_ s: WorkoutSession, history: [WorkoutSession], calendar: Calendar = .current) -> [PyramidRow] {
        let since = calendar.date(byAdding: .day, value: -30, to: s.startedAt) ?? s.startedAt
        let window = history.filter { $0.id != s.id && $0.startedAt >= since && $0.startedAt < s.startedAt }
        func sends(_ sessions: [WorkoutSession]) -> [String: Int] {
            var out: [String: Int] = [:]
            for x in sessions { for ex in x.exercises where ex.kind == .climbAttempt {
                for set in ex.sets where set.completedAt != nil && SetMeasure.isSend(set) {
                    if let g = set.climbGradeLabel ?? ex.climbGradeLabel { out[g, default: 0] += 1 }
                }
            } }
            return out
        }
        let today = sends([s]), past = sends(window)
        let scale = s.exercises.first { $0.kind == .climbAttempt }?.climbGradeScale ?? .vScale
        let grades = Set(today.keys).union(past.keys)
        return grades.sorted { (scale.difficulty(for: $0) ?? 0) > (scale.difficulty(for: $1) ?? 0) }
            .map { PyramidRow(grade: $0, today: today[$0] ?? 0, last30: past[$0] ?? 0) }
    }

    // MARK: - Building blocks

    static func completedSets(_ s: WorkoutSession) -> Int { s.exercises.reduce(0) { $0 + $1.completedSetCount } }

    static func volumeKg(_ s: WorkoutSession) -> Double {
        s.exercises.filter { $0.kind == .repsWeight }.flatMap { $0.sets.filter { $0.completedAt != nil } }
            .reduce(0) { acc, set in
                let w = WorkoutMath.toKg(set.actualWeight ?? 0, set.weightUnit)
                return acc + (w > 0 ? w * Double(set.actualReps ?? 0) : 0)
            }
    }

    static func totalReps(_ s: WorkoutSession, weightedOnly: Bool) -> Int {
        s.exercises.filter { $0.kind == .repsWeight }.flatMap { $0.sets.filter { $0.completedAt != nil } }
            .filter { !weightedOnly || ($0.actualWeight ?? 0) > 0 }.compactMap(\.actualReps).reduce(0, +)
    }

    static func maxReps(_ s: WorkoutSession) -> Int {
        s.exercises.flatMap { $0.sets.filter { $0.completedAt != nil } }.compactMap(\.actualReps).max() ?? 0
    }

    static func topSet(_ s: WorkoutSession) -> (kg: Double, reps: Int)? {
        let sets = s.exercises.filter { $0.kind == .repsWeight }.flatMap { $0.sets.filter { $0.completedAt != nil } }
            .filter { ($0.actualWeight ?? 0) > 0 }
        guard let top = sets.max(by: { WorkoutMath.toKg($0.actualWeight ?? 0, $0.weightUnit) < WorkoutMath.toKg($1.actualWeight ?? 0, $1.weightUnit) })
        else { return nil }
        return (WorkoutMath.toKg(top.actualWeight ?? 0, top.weightUnit), top.actualReps ?? 0)
    }

    static func maxLoadKg(_ s: WorkoutSession) -> Double? {
        s.exercises.flatMap { $0.sets.filter { $0.completedAt != nil } }.compactMap(\.loadKg).max()
    }

    static func peakForce(_ s: WorkoutSession) -> Double? {
        s.exercises.flatMap { $0.sets.flatMap { $0.forceReps ?? [] } }.map(\.peakKg).max()
    }

    static func forceRepCount(_ s: WorkoutSession) -> Int {
        s.exercises.flatMap { $0.sets.flatMap { $0.forceReps ?? [] } }.count
    }

    /// Hangs prescribed by the protocol(s) that were run (sets × reps × hands).
    static func plannedHangs(_ s: WorkoutSession) -> Int? {
        let specs = s.exercises.filter { $0.completedSetCount > 0 }.compactMap(\.timedSpec).filter { $0.mode.isStructured }
        guard !specs.isEmpty else { return nil }
        return specs.reduce(0) { $0 + $1.sets * $1.effectiveRepsPerSet }
    }

    static func holdTime(_ s: WorkoutSession) -> Double {
        s.exercises.filter { $0.kind == .duration && $0.discipline != .run }
            .flatMap { $0.sets.filter { $0.completedAt != nil } }.compactMap(\.durationSec).reduce(0, +)
    }

    static func bestHold(_ s: WorkoutSession) -> Double {
        s.exercises.filter { $0.kind == .duration && $0.discipline != .run }
            .flatMap { $0.sets.filter { $0.completedAt != nil } }.compactMap(\.durationSec).max() ?? 0
    }

    static func climbs(_ s: WorkoutSession) -> (sends: Int, attempts: Int, hardest: String?, hardestDifficulty: Double?) {
        var sends = 0, attempts = 0
        var best: (String, Double)?
        for ex in s.exercises where ex.kind == .climbAttempt {
            for set in ex.sets where set.completedAt != nil {
                attempts += set.climbAttempts ?? 1
                guard SetMeasure.isSend(set), let g = set.climbGradeLabel ?? ex.climbGradeLabel else { continue }
                sends += 1
                let d = ex.climbGradeScale.difficulty(for: g) ?? -1
                if best.map({ d > $0.1 }) ?? true { best = (g, d) }
            }
        }
        return (sends, attempts, best?.0, best?.1)
    }

    static func runTotals(_ s: WorkoutSession) -> (meters: Double, seconds: Double) {
        var m = 0.0, t = 0.0
        for ex in s.exercises where ex.discipline == .run {
            for set in ex.sets where set.completedAt != nil {
                m += set.distanceMeters ?? 0
                t += set.durationSec ?? 0
            }
        }
        return (m, t)
    }

    static func avgHR(_ s: WorkoutSession) -> Double? {
        guard !s.hrSeries.isEmpty else { return nil }
        return s.hrSeries.map(\.bpm).reduce(0, +) / Double(s.hrSeries.count)
    }

    static func signedLoad(_ kg: Double) -> String {
        "\(kg >= 0 ? "+" : "−")\(SetMeasure.formatWeight(round2(abs(kg))))"
    }

    static func groupedWeight(_ kg: Double, _ unit: WeightUnit) -> String {
        WorkoutMath.kgToUnit(kg, unit).rounded().formatted(.number.grouping(.automatic))
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
