import Foundation

// MARK: - Recap Feed — pure composer (F0 keystone)
//
// `FeedComposer.compose(...)` turns plain-value session/log/all-time inputs into an
// ordered set of ephemeral `FeedCard`s. Each card-recipe declares its own eligibility
// (it is simply never produced when its trigger data is absent) so the feed
// degrades by construction across iOS/Android. Ordering is recency-bounded:
// `salience × recencyDecay(anchorDate)` so an old high-salience PR never out-floats a
// fresh session. The engine reads the existing pure engines (`KilterSessionStats`,
// `KilterAllTimeStats`) and only SURFACES their numbers — it never re-derives math.
//
// PURE: no SwiftData / UIKit / SwiftUI. Inputs are plain values (no @Model parameters),
// so the same shape compiles in Kotlin (FA0) and the golden corpus reproduces verbatim.
// The @Model → input bridges live in FeedInputs.swift (not used by the pure core/tests).

// MARK: Window & lens

/// Compose window. F0 exercises `.allTime`; the Story Player (F6) calls the period windows.
enum FeedWindow: Sendable, Equatable {
    case allTime
    case thisWeek, thisMonth, thisYear
    case interval(DateInterval)
}

/// Client-side feed lens (the Lens bar). Pure post-filter so F1 reuses it.
enum FeedLens: Sendable, Equatable {
    case all
    case category(FeedCategory)
    case sessionsOnly
}

// MARK: Plain-value inputs (no @Model)

struct KilterSessionInput: Sendable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var angle: Int
    var title: String?
    var layoutId: Int?
    // F2: optional HR — default empty so the golden corpus stays shared-fields-only; e1/e2 gate on non-empty.
    var hrSeries: [HRPoint] = []
    var maxHR: Double? = nil
    var restHR: Double? = nil

    init(id: UUID, startedAt: Date, endedAt: Date? = nil, angle: Int, title: String? = nil, layoutId: Int? = nil,
         hrSeries: [HRPoint] = [], maxHR: Double? = nil, restHR: Double? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.angle = angle; self.title = title; self.layoutId = layoutId
        self.hrSeries = hrSeries; self.maxHR = maxHR; self.restHR = restHR
    }
}

struct WorkoutSetInput: Sendable, Equatable {
    var actualReps: Int?
    var actualWeight: Double?
    var durationSec: Double?
    var distanceMeters: Double?
    var completedAt: Date?

    init(actualReps: Int? = nil, actualWeight: Double? = nil, durationSec: Double? = nil,
         distanceMeters: Double? = nil, completedAt: Date? = nil) {
        self.actualReps = actualReps; self.actualWeight = actualWeight
        self.durationSec = durationSec; self.distanceMeters = distanceMeters
        self.completedAt = completedAt
    }
}

struct WorkoutExerciseInput: Sendable, Equatable {
    var exerciseId: String
    var disciplineRaw: String?
    var displayName: String?
    var skipped: Bool
    var sets: [WorkoutSetInput]

    init(exerciseId: String = "", disciplineRaw: String? = nil, displayName: String? = nil, skipped: Bool = false, sets: [WorkoutSetInput] = []) {
        self.exerciseId = exerciseId; self.disciplineRaw = disciplineRaw; self.displayName = displayName
        self.skipped = skipped; self.sets = sets
    }
}

/// A "lit on the board" event (F5 a3) — plain value.
struct LitEventInput: Sendable, Equatable {
    var climbUUID: String
    var gradeLabel: String
    var difficulty: Double
    var sessionId: String?
    var litAt: Date

    init(climbUUID: String, gradeLabel: String, difficulty: Double = 0, sessionId: String? = nil, litAt: Date) {
        self.climbUUID = climbUUID; self.gradeLabel = gradeLabel; self.difficulty = difficulty
        self.sessionId = sessionId; self.litAt = litAt
    }
}

struct WorkoutSessionInput: Sendable, Equatable, Identifiable {
    var id: UUID
    var routineName: String
    var startedAt: Date
    var completedAt: Date?
    var exercises: [WorkoutExerciseInput]

    init(id: UUID, routineName: String, startedAt: Date, completedAt: Date? = nil, exercises: [WorkoutExerciseInput] = []) {
        self.id = id; self.routineName = routineName; self.startedAt = startedAt
        self.completedAt = completedAt; self.exercises = exercises
    }
}

// MARK: Composer

enum FeedComposer {

    /// Base salience tiers. PR > most-climbs > streak > trend > routine session.
    enum Salience {
        static let gradePR = 1.0
        static let mostClimbs = 0.9
        static let streak = 0.8
        static let liftPR = 0.85         // F5: a gym PR (just under a grade PR)
        static let trend = 0.6
        static let hardestEffort = 0.7   // F2: e2 > e1 > e3
        static let effort = 0.55
        static let hrTrend = 0.5
        static let climbSession = 0.45
        static let onTheBoard = 0.42     // F5: board session without a full log
        static let workoutSession = 0.40
        static let insightMemory = 0.65  // F6: on-this-day (memory)
        static let consistency = 0.55     // F6: consistency map
    }

    /// Recency half-life. Decay is exp(-age/halfLife); 7 days keeps recent PRs ahead of
    /// fresh sessions for a few days, then a fresh session overtakes a stale PR (the recency bound).
    static let recencyHalfLife: TimeInterval = 7 * 24 * 3600

    static func recencyDecay(_ anchor: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(anchor))   // clamp: anchorDate <= now
        return exp(-age / recencyHalfLife)
    }

    /// The single entry point. The infinite feed calls `.allTime`; the Story Player uses period windows.
    static func compose(window: FeedWindow = .allTime,
                        kilterSessions: [KilterSessionInput] = [],
                        kilterLogs: [KilterClimbLog] = [],
                        workoutSessions: [WorkoutSessionInput] = [],
                        kilterLitEvents: [LitEventInput] = [],
                        mediaCountBySession: [UUID: Int] = [:],
                        allTimeStats: KilterAllTimeStats = .empty,
                        now: Date,
                        calendar: Calendar = .current) -> [FeedCard] {

        let (prCards, prKeys) = gradePRCards(logs: kilterLogs)
        let lastAct = lastActivity(sessions: kilterSessions, logs: kilterLogs, workouts: workoutSessions)

        var cards: [FeedCard] = []
        cards += climbSessionCards(sessions: kilterSessions, logs: kilterLogs, prKeys: prKeys, mediaCountBySession: mediaCountBySession)
        cards += workoutSessionCards(workouts: workoutSessions)
        cards += prCards
        cards += mostClimbsCards(sessions: kilterSessions, logs: kilterLogs)
        cards += streakCards(sessions: kilterSessions, workouts: workoutSessions, calendar: calendar)
        cards += pyramidCards(allTime: allTimeStats, anchor: lastAct ?? now)
        cards += weeklyVolumeCards(allTime: allTimeStats, anchor: lastAct ?? now)
        // F2 — HR-deepened cards (registered here; never composed when hrSeries is absent).
        cards += FeedHRCards.cards(sessions: kilterSessions, logs: kilterLogs)
        cards += FeedHRCards.trend(sessions: kilterSessions)
        // F5 — more milestones.
        cards += liftPRCards(workouts: workoutSessions)
        cards += onTheBoardCards(litEvents: kilterLitEvents, loggedSessionIds: Set(kilterLogs.compactMap { $0.sessionId }))
        // F6 — cross-session insight menu (registry entries; pure, all-time/log-scan derived).
        cards += FeedInsightCards.cards(allTime: allTimeStats, logs: kilterLogs, now: now, calendar: calendar, anchor: lastAct ?? now)
        // F6 follow-on — the rest of the insight menu (project/grade, trends, HR-effort).
        cards += FeedProjectCards.cards(logs: kilterLogs, now: now, calendar: calendar, anchor: lastAct ?? now)
        cards += FeedTrendCards.cards(allTime: allTimeStats, kilterSessions: kilterSessions,
                                      workoutSessions: workoutSessions, logs: kilterLogs,
                                      now: now, calendar: calendar, anchor: lastAct ?? now)
        cards += FeedEffortInsights.cards(kilterSessions: kilterSessions, logs: kilterLogs,
                                          now: now, calendar: calendar, anchor: lastAct ?? now)

        let windowed = cards.filter { inWindow($0.anchorDate, window: window, now: now, calendar: calendar) }
        return ordered(windowed, now: now)
    }

    // MARK: Ordering (recency-bounded)

    static func ordered(_ cards: [FeedCard], now: Date) -> [FeedCard] {
        cards.sorted { a, b in
            let sa = a.salience * recencyDecay(a.anchorDate, now: now)
            let sb = b.salience * recencyDecay(b.anchorDate, now: now)
            if abs(sa - sb) > 1e-9 { return sa > sb }
            if a.anchorDate != b.anchorDate { return a.anchorDate > b.anchorDate }
            return a.id < b.id
        }
    }

    // MARK: Lens (pure post-filter)

    static func filter(_ cards: [FeedCard], lens: FeedLens) -> [FeedCard] {
        switch lens {
        case .all:
            return cards
        case .sessionsOnly:
            return cards.filter { $0.kind == .a1Session || $0.kind == .a2Session }
        case .category(let c):
            return cards.filter { $0.category == c }
        }
    }

    // MARK: - Recipes

    private static func climbSessionCards(sessions: [KilterSessionInput], logs: [KilterClimbLog], prKeys: Set<String>, mediaCountBySession: [UUID: Int]) -> [FeedCard] {
        let bySession = Dictionary(grouping: logs.filter { $0.sessionId != nil }, by: { $0.sessionId! })
        var out: [FeedCard] = []
        for s in sessions {
            let slogs = bySession[s.id] ?? []
            guard !slogs.isEmpty else { continue }                      // eligibility: >=1 logged climb
            let end = s.endedAt ?? slogs.map(\.loggedAt).max() ?? s.startedAt
            let stats = KilterSessionStats.make(from: slogs, start: s.startedAt, end: end)
            let isPR = slogs.contains { prKeys.contains(prKey($0)) }
            let payload = ClimbSessionPayload(
                title: s.title,
                hardestSendGrade: stats.hardestSendGrade,
                totalClimbs: stats.totalClimbs, sends: stats.sends, projects: stats.projects,
                attemptsOnly: stats.attemptsOnly, totalAttempts: stats.totalAttempts,
                durationSec: stats.totalDuration, angle: s.angle,
                pyramid: stats.pyramid.map(Self.row(from:)), isPRSession: isPR,
                clipCount: mediaCountBySession[s.id] ?? 0)
            out.append(FeedCard(id: "a1-\(s.id.uuidString)", contentId: FeedContentIdentity.kilterSession(id: s.id.uuidString),
                                kind: .a1Session, category: .climbing,
                                salience: Salience.climbSession, anchorDate: end,
                                sourceRefs: [ActivityRef(objectKind: "kilterSession", ref: s.id.uuidString)],
                                payload: .climbSession(payload), shareHint: .sessionReceipt))
        }
        return out
    }

    private static func workoutSessionCards(workouts: [WorkoutSessionInput]) -> [FeedCard] {
        var out: [FeedCard] = []
        for w in workouts {
            guard let end = w.completedAt else { continue }            // eligibility: completed
            let completedSets = w.exercises.flatMap(\.sets).filter { $0.completedAt != nil }
            guard !completedSets.isEmpty else { continue }              // & >=1 completed set
            let volume = completedSets.reduce(0.0) { $0 + Double($1.actualReps ?? 0) * ($1.actualWeight ?? 0) }
            let distance = completedSets.compactMap(\.distanceMeters).reduce(0, +)
            let payload = WorkoutSessionPayload(
                title: w.routineName, disciplineRaw: dominantDiscipline(w.exercises),
                totalVolume: volume, distanceMeters: distance > 0 ? distance : nil,
                exerciseCount: w.exercises.filter { !$0.skipped }.count,
                setCount: completedSets.count, durationSec: end.timeIntervalSince(w.startedAt))
            out.append(FeedCard(id: "a2-\(w.id.uuidString)", contentId: FeedContentIdentity.workoutSession(id: w.id.uuidString),
                                kind: .a2Session, category: .strength,
                                salience: Salience.workoutSession, anchorDate: end,
                                sourceRefs: [ActivityRef(objectKind: "workoutSession", ref: w.id.uuidString)],
                                payload: .workoutSession(payload), shareHint: .sessionReceipt))
        }
        return out
    }

    /// Returns the PR cards plus the set of PR send keys (so a1 can flag a PR session).
    private static func gradePRCards(logs: [KilterClimbLog]) -> (cards: [FeedCard], prKeys: Set<String>) {
        let sends = logs.filter(\.isSend).sorted { $0.loggedAt < $1.loggedAt }
        var out: [FeedCard] = []
        var keys: Set<String> = []
        var priorMax: Double? = nil
        var priorGrade: String? = nil
        for s in sends where (priorMax == nil || s.difficulty > priorMax!) {
            let payload = GradePRPayload(newGrade: s.gradeLabel, newDifficulty: s.difficulty,
                                         previousGrade: priorGrade, climbName: s.climbName)
            let cid = FeedContentIdentity.kilterSend(climbUUID: s.climbUUID, difficulty: s.difficulty,
                                                     statusRaw: s.status.rawValue, date: s.loggedAt,
                                                     sessionId: s.sessionId?.uuidString)
            out.append(FeedCard(id: "b1-\(prKey(s))", contentId: cid, kind: .b1GradePR, category: .milestone,
                                salience: Salience.gradePR, anchorDate: s.loggedAt,
                                sourceRefs: [ActivityRef(objectKind: "climb", ref: s.climbUUID)],
                                payload: .gradePR(payload), shareHint: .gradePRTicket))
            keys.insert(prKey(s))
            priorMax = s.difficulty
            priorGrade = s.gradeLabel
        }
        return (out, keys)
    }

    private static func mostClimbsCards(sessions: [KilterSessionInput], logs: [KilterClimbLog]) -> [FeedCard] {
        let bySession = Dictionary(grouping: logs.filter { $0.sessionId != nil }, by: { $0.sessionId! })
        let counted = sessions.compactMap { s -> (KilterSessionInput, Int, Date)? in
            guard let slogs = bySession[s.id], !slogs.isEmpty else { return nil }
            return (s, slogs.count, s.endedAt ?? slogs.map(\.loggedAt).max() ?? s.startedAt)
        }.sorted { $0.0.startedAt < $1.0.startedAt }
        var out: [FeedCard] = []
        var priorRecord = 0
        for (s, count, end) in counted {
            if priorRecord > 0 && count > priorRecord {                 // beats a PRIOR record only
                out.append(FeedCard(id: "b3-\(s.id.uuidString)", contentId: FeedContentIdentity.kilterSession(id: s.id.uuidString),
                                    kind: .b3MostClimbs, category: .milestone,
                                    salience: Salience.mostClimbs, anchorDate: end,
                                    sourceRefs: [ActivityRef(objectKind: "kilterSession", ref: s.id.uuidString)],
                                    payload: .mostClimbs(MostClimbsPayload(count: count, previousRecord: priorRecord)),
                                    shareHint: nil))
            }
            priorRecord = max(priorRecord, count)
        }
        return out
    }

    private static func streakCards(sessions: [KilterSessionInput], workouts: [WorkoutSessionInput], calendar: Calendar) -> [FeedCard] {
        var days = Set<Date>()
        for s in sessions { days.insert(calendar.startOfDay(for: s.startedAt)) }
        for w in workouts where w.completedAt != nil { days.insert(calendar.startOfDay(for: w.startedAt)) }
        guard let latest = days.max() else { return [] }
        var streak = 0
        var cursor: Date? = latest
        while let day = cursor, days.contains(day) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        guard streak >= 3 else { return [] }                           // eligibility: streak >= 3 days
        return [FeedCard(id: "b5-streak-\(Int(latest.timeIntervalSince1970))", kind: .b5Streak, category: .milestone,
                         salience: Salience.streak, anchorDate: latest,
                         sourceRefs: [ActivityRef(objectKind: "aggregate", ref: "streak")],
                         payload: .streak(StreakPayload(days: streak, weeks: streak / 7)), shareHint: nil)]
    }

    private static func pyramidCards(allTime: KilterAllTimeStats, anchor: Date) -> [FeedCard] {
        let totalSends = allTime.pyramid.reduce(0) { $0 + $1.sends }
        let gradesWithSends = allTime.pyramid.filter { $0.sends > 0 }.count
        guard totalSends >= 15, gradesWithSends >= 3 else { return [] }  // eligibility threshold
        let payload = PyramidPayload(rows: allTime.pyramid.map(Self.row(from:)),
                                     totalSends: totalSends, maxGrade: allTime.maxGradeLabel)
        return [FeedCard(id: "c1-pyramid", kind: .c1Pyramid, category: .trend,
                         salience: Salience.trend, anchorDate: anchor,
                         sourceRefs: [ActivityRef(objectKind: "aggregate", ref: "pyramid")],
                         payload: .pyramid(payload), shareHint: .pyramidCard)]
    }

    private static func weeklyVolumeCards(allTime: KilterAllTimeStats, anchor: Date) -> [FeedCard] {
        let buckets = allTime.sendsPerWeek
        guard buckets.filter({ $0.sends > 0 }).count >= 2 else { return [] }   // >=2 non-empty weeks
        let delta = (buckets.last?.sends ?? 0) - (buckets.dropLast().last?.sends ?? 0)
        let payload = WeeklyVolumePayload(
            buckets: buckets.map { .init(label: $0.periodLabel, sends: $0.sends) }, deltaVsPrev: delta)
        return [FeedCard(id: "d1-weekvol", kind: .d1WeeklyVolume, category: .trend,
                         salience: Salience.trend, anchorDate: anchor,
                         sourceRefs: [ActivityRef(objectKind: "aggregate", ref: "weeklyVolume")],
                         payload: .weeklyVolume(payload), shareHint: nil)]
    }

    // F5 — gym est-1RM (Epley) personal records per exercise.
    private static func liftPRCards(workouts: [WorkoutSessionInput]) -> [FeedCard] {
        struct Done { let date: Date; let key: String; let name: String; let reps: Int; let weight: Double; let sessionId: UUID }
        var done: [Done] = []
        for w in workouts where w.completedAt != nil {
            for ex in w.exercises where !ex.skipped {
                for set in ex.sets {
                    guard set.completedAt != nil, let reps = set.actualReps, reps > 0,
                          let weight = set.actualWeight, weight > 0, let date = set.completedAt else { continue }
                    let key = ex.exerciseId.isEmpty ? (ex.displayName ?? "exercise") : ex.exerciseId
                    done.append(Done(date: date, key: key, name: ex.displayName ?? key, reps: reps, weight: weight, sessionId: w.id))
                }
            }
        }
        done.sort { $0.date < $1.date }
        var best: [String: Double] = [:]
        var out: [FeedCard] = []
        for d in done {
            let orm = d.weight * (1 + Double(d.reps) / 30)        // Epley est-1RM
            let prior = best[d.key]
            if prior == nil || orm > prior! + 0.01 {
                if let prior {                                    // celebrate only when beating a PRIOR best
                    let cid = FeedContentIdentity.workoutSession(id: d.sessionId.uuidString)
                    let payload = LiftPRPayload(exerciseName: d.name, oneRepMaxKg: orm, weightKg: d.weight,
                                                reps: d.reps, previousOneRepMaxKg: prior)
                    out.append(FeedCard(id: "b4-\(d.key)-\(Int(d.date.timeIntervalSince1970))", contentId: cid,
                                        kind: .b4LiftPR, category: .milestone, salience: Salience.liftPR, anchorDate: d.date,
                                        sourceRefs: [ActivityRef(objectKind: "workoutSession", ref: d.sessionId.uuidString)],
                                        payload: .liftPR(payload), shareHint: .gradePRTicket))
                }
                best[d.key] = orm
            }
        }
        return out
    }

    // F5 — "On the Board": a session with lit climbs but NO full log (the degraded path).
    private static func onTheBoardCards(litEvents: [LitEventInput], loggedSessionIds: Set<UUID>) -> [FeedCard] {
        let withSession = litEvents.compactMap { e -> (UUID, LitEventInput)? in
            guard let sid = e.sessionId, let uuid = UUID(uuidString: sid) else { return nil }
            return (uuid, e)
        }
        let bySession = Dictionary(grouping: withSession, by: { $0.0 }).mapValues { $0.map(\.1) }
        var out: [FeedCard] = []
        for (sid, events) in bySession where !loggedSessionIds.contains(sid) && !events.isEmpty {
            let sorted = events.sorted { $0.difficulty < $1.difficulty }
            let spread = sorted.first?.gradeLabel == sorted.last?.gradeLabel
                ? (sorted.first?.gradeLabel ?? "")
                : "\(sorted.first?.gradeLabel ?? "")–\(sorted.last?.gradeLabel ?? "")"
            let anchor = events.map(\.litAt).max() ?? Date(timeIntervalSince1970: 0)
            let payload = OnTheBoardPayload(litCount: events.count, hardestGrade: sorted.last?.gradeLabel, gradeSpread: spread)
            out.append(FeedCard(id: "a3-\(sid.uuidString)", contentId: FeedContentIdentity.kilterSession(id: sid.uuidString),
                                kind: .a3OnTheBoard, category: .climbing, salience: Salience.onTheBoard, anchorDate: anchor,
                                sourceRefs: [ActivityRef(objectKind: "kilterSession", ref: sid.uuidString)],
                                payload: .onTheBoard(payload), shareHint: nil))
        }
        return out.sorted { $0.anchorDate > $1.anchorDate }
    }

    // MARK: - Helpers

    private static func row(from g: KilterSessionStats.GradeCount) -> PyramidRow {
        PyramidRow(grade: g.gradeLabel, difficulty: g.difficulty, sends: g.sends,
                   flashes: g.flashes, projects: g.projects, attemptsOnly: g.attemptsOnly)
    }

    /// Identity of a single send for PR matching across recipes (shared-field only — Android-safe).
    private static func prKey(_ log: KilterClimbLog) -> String {
        "\(log.climbUUID)@\(Int(log.loggedAt.timeIntervalSince1970 * 1000))"
    }

    private static func dominantDiscipline(_ exercises: [WorkoutExerciseInput]) -> String {
        let raws = exercises.filter { !$0.skipped }.compactMap { $0.disciplineRaw }
        guard !raws.isEmpty else { return "strength" }
        let counts = Dictionary(grouping: raws, by: { $0 }).mapValues(\.count)
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? "strength"
    }

    private static func lastActivity(sessions: [KilterSessionInput], logs: [KilterClimbLog], workouts: [WorkoutSessionInput]) -> Date? {
        var dates: [Date] = logs.map(\.loggedAt)
        dates += sessions.map { $0.endedAt ?? $0.startedAt }
        dates += workouts.map { $0.completedAt ?? $0.startedAt }
        return dates.max()
    }

    private static func inWindow(_ date: Date, window: FeedWindow, now: Date, calendar: Calendar) -> Bool {
        switch window {
        case .allTime:
            return true
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) ?? true
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.contains(date) ?? true
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)?.contains(date) ?? true
        case .interval(let i):
            return i.contains(date)
        }
    }
}
