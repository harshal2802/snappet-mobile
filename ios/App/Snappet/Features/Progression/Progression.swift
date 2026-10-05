import Foundation

/// XP, levels and Form (progression P1, prompt 148; wireframe `docs/ux-research/progression/`).
/// Everything is derived from the sessions you already have — nothing is stored — so past history
/// counts automatically ("backfill"), editing a session re-judges it, and the rules live in one table.
@MainActor
enum Progression {

    // MARK: - Rules (one table, so they're easy to tune)

    enum Rules {
        static let finish = 50
        static let perMinute = 1
        static let minuteCap = 60
        static let onPlan = 20
        static let record = 25
        static let recordMax = 3
        static let milestone = 50
        static let streakPerWeek = 10
        static let streakCap = 100
        static let healthImport = 25
        static let dailyCap = 300
        /// A household chore you're credited with, by effort (household prompt 01).
        static let choreS = 10
        static let choreM = 20
        static let choreL = 35
        nonisolated static func choreXP(_ effort: ChoreEffort) -> Int {
            switch effort {
            case .s: return choreS
            case .m: return choreM
            case .l: return choreL
            }
        }
        /// A session shorter than this, or with nothing completed, earns nothing. (`-uiTestXPAnyLength`
        /// lifts it so a UI test's seconds-long session can show the XP card.)
        static let minSeconds: TimeInterval =
            ProcessInfo.processInfo.arguments.contains("-uiTestXPAnyLength") ? 0 : 300
    }

    struct XPItem: Equatable, Sendable {
        var label: String
        var xp: Int
    }

    /// XP earned outside a workout session (household chores, prompt 01), folded into the same ledger
    /// and daily cap. `id` keys its award; it never collides with a session id.
    struct Earning: Equatable, Sendable {
        var id: UUID
        var at: Date
        var items: [XPItem]
    }

    struct Award: Equatable, Sendable {
        var items: [XPItem]
        /// After the daily cap.
        var total: Int
        /// True when the daily cap trimmed this session's XP.
        var capped: Bool
    }

    // MARK: - XP for one session

    /// The uncapped XP lines for `s`. `earlier` = every completed session before it (any routine);
    /// `schedule` = its routine's schedule, for "on plan".
    static func items(for s: WorkoutSession, earlier: [WorkoutSession], schedule: RoutineSchedule?,
                      unit: WeightUnit = .kg, pauses: [Pause] = [], calendar: Calendar = .current) -> [XPItem] {
        let memo = Memo(calendar: calendar, pauses: pauses)
        earlier.forEach(memo.add)
        return items(for: s, earlier: earlier, schedule: schedule, unit: unit, calendar: calendar, memo: memo)
    }

    /// Per-pass lookups so walking the whole history stays ~linear per session: each session's week
    /// start and workout type are worked out once, and `weeks` holds the weeks trained so far.
    final class Memo {
        let calendar: Calendar
        let pauses: [Pause]
        private(set) var weeks: Set<Date> = []
        private var kinds: [UUID: SessionInsights.Kind] = [:]
        init(calendar: Calendar, pauses: [Pause] = []) { self.calendar = calendar; self.pauses = pauses }

        func week(_ d: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d }
        func kind(_ s: WorkoutSession) -> SessionInsights.Kind {
            if let k = kinds[s.id] { return k }
            let k = SessionInsights.Kind.of(s)
            kinds[s.id] = k
            return k
        }
        func add(_ s: WorkoutSession) { weeks.insert(week(s.startedAt)) }

        /// The streak in `d`'s week (that week counted as trained), with freezes and pauses applied.
        func streak(endingAt d: Date) -> Int {
            let w = week(d)
            return Progression.streak(trainedWeeks: weeks.union([w]), pauses: pauses, through: w,
                                      inProgress: nil, calendar: calendar).weeks
        }
    }

    static func items(for s: WorkoutSession, earlier: [WorkoutSession], schedule: RoutineSchedule?,
                      unit: WeightUnit, calendar: Calendar, memo: Memo) -> [XPItem] {
        guard s.duration >= Rules.minSeconds else { return [] }
        if s.isImportedFromHealth {
            return [XPItem(label: "Apple Health workout", xp: Rules.healthImport)]
        }
        guard s.completedSetCount > 0 else { return [] }

        var out = [XPItem(label: "Session finished", xp: Rules.finish)]
        let minutes = min(Rules.minuteCap, Int(s.duration / 60))
        out.append(XPItem(label: "\(minutes) active minutes", xp: minutes * Rules.perMinute))

        if SessionInsights.onPlan(s, schedule: schedule, calendar: calendar) == true {
            out.append(XPItem(label: "On plan · \(s.startedAt.formatted(.dateTime.weekday(.wide)))", xp: Rules.onPlan))
        }

        let logged = earlier.filter { !$0.isImportedFromHealth }
        let series = SessionInsights.comparable(for: s, in: logged, kindOf: memo.kind)
        let badges = SessionInsights.badges(s, prior: series, allHistory: logged,
                                            resolve: exerciseName, unit: unit,
                                            includeStreak: false)
        for label in badges.compactMap(recordLabel).prefix(Rules.recordMax) {
            out.append(XPItem(label: "🏆 " + label, xp: Rules.record))
        }
        for case .sessionCount(let n, let name) in badges {
            out.append(XPItem(label: "🎯 \(SessionInsights.ordinal(n)) \(name)", xp: Rules.milestone))
        }

        // Week streak: once a week, on that week's first session.
        if !memo.weeks.contains(memo.week(s.startedAt)) {
            let weeks = memo.streak(endingAt: s.startedAt)
            if weeks >= 2 {
                out.append(XPItem(label: "🔥 \(weeks)-week streak", xp: min(Rules.streakCap, weeks * Rules.streakPerWeek)))
            }
        }
        return out
    }

    /// A record's exercise name without needing the custom-exercise list (custom ones carry a name).
    static func exerciseName(_ ex: SessionExercise) -> String {
        ex.displayName ?? ExerciseCatalog.byID[ex.exerciseId]?.name ?? "Exercise"
    }

    /// The records that earn XP (firsts of a series and counts are handled separately).
    static func recordLabel(_ b: SessionInsights.Badge) -> String? {
        switch b {
        case .weightPR(let ex, _, _, _): return "\(ex) PR"
        case .repPR(let ex, _): return "\(ex) rep PR"
        case .bestVolume: return "Best volume"
        case .heaviestLoad: return "Heaviest hang"
        case .peakForcePR: return "Peak force PR"
        case .firstSend(let g): return "First \(g) send"
        case .mostSends: return "Most sends"
        case .fastestPace: return "Fastest pace"
        case .longestDistance: return "Longest run"
        case .firstOfSeries, .sessionCount, .weekStreak: return nil
        }
    }

    // MARK: - The ledger: every session's award, oldest first, with the daily cap

    struct Ledger: Equatable, Sendable {
        var awards: [UUID: Award]
        var totalXP: Int
        /// Completed, XP-earning sessions counted.
        var sessionCount: Int

        static let empty = Ledger(awards: [:], totalXP: 0, sessionCount: 0)

        /// Total XP before `id` was earned (for "the bar fills from where it was").
        func xp(before id: UUID) -> Int { totalXP - (awards[id]?.total ?? 0) }
    }

    /// Each session's XP lines, keyed by a fingerprint of it AND everything before it (records depend
    /// on history). Finishing a session then costs one session's work, and editing an old one only
    /// recomputes from there on. In memory only — the ledger is always derivable from the sessions.
    private static var cache: [UUID: (key: Int, lines: [XPItem])] = [:]

    /// A cheap, exact fingerprint of what a session's XP depends on.
    private static func fingerprint(_ s: WorkoutSession, schedule: RoutineSchedule?) -> Int {
        var h = Hasher()
        h.combine(s.id); h.combine(s.startedAt); h.combine(s.completedAt); h.combine(s.routineID)
        h.combine(s.routineName); h.combine(s.healthKitWorkoutUUID); h.combine(s.exercises); h.combine(schedule)
        return h.finalize()
    }

    /// `sessions` = everything (active sessions are ignored unless passed as `including`, the one
    /// being finished right now). `schedules` = routine id → schedule. `extras` = XP from outside sessions
    /// (chores), defaulting to what the household publishes so every caller agrees on the total. They share
    /// the daily cap in time order but don't count as sessions.
    @MainActor
    static func ledger(_ sessions: [WorkoutSession], including current: WorkoutSession? = nil,
                       schedules: [UUID: RoutineSchedule], unit: WeightUnit = .kg, pauses: [Pause] = [],
                       extras: [Earning] = HouseholdXP.shared.earnings,
                       calendar: Calendar = .current) -> Ledger {
        var all = sessions.filter { $0.completedAt != nil && $0.id != current?.id }
        if let current { all.append(current) }
        all.sort { $0.startedAt < $1.startedAt }

        var entries: [(id: UUID, at: Date, lines: [XPItem], isSession: Bool)] = []
        let memo = Memo(calendar: calendar, pauses: pauses)
        var prefix = Hasher()
        prefix.combine(unit); prefix.combine(calendar.firstWeekday); prefix.combine(calendar.timeZone.identifier)
        prefix.combine(pauses)
        for (i, s) in all.enumerated() {
            defer { memo.add(s) }
            let schedule = s.routineID.flatMap { schedules[$0] }
            prefix.combine(fingerprint(s, schedule: schedule))
            var probe = prefix
            let key = probe.finalize()
            let lines: [XPItem]
            if let hit = cache[s.id], hit.key == key {
                lines = hit.lines
            } else {
                lines = items(for: s, earlier: Array(all[..<i]), schedule: schedule, unit: unit,
                              calendar: calendar, memo: memo)
                cache[s.id] = (key, lines)
            }
            guard !lines.isEmpty else { continue }
            entries.append((s.id, s.startedAt, lines, true))
        }
        // Chores and sessions share the daily cap, first come first served (stable: a session and a
        // chore at the same instant keep sessions first).
        entries += extras.filter { !$0.items.isEmpty }.map { ($0.id, $0.at, $0.items, false) }
        if !extras.isEmpty {
            entries = entries.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        }

        var awards: [UUID: Award] = [:]
        var perDay: [DayKey: Int] = [:]
        var total = 0, counted = 0
        for e in entries {
            let raw = e.lines.reduce(0) { $0 + $1.xp }
            let day = DayKey(e.at, calendar: calendar)
            let room = max(0, Rules.dailyCap - perDay[day, default: 0])
            let earned = min(raw, room)
            perDay[day, default: 0] += earned
            awards[e.id] = Award(items: e.lines, total: earned, capped: earned < raw)
            total += earned
            if e.isSession { counted += 1 }
        }
        return Ledger(awards: awards, totalXP: total, sessionCount: counted)
    }

    // MARK: - Levels (permanent) and stages

    /// XP to go from level `n` to `n + 1`.
    nonisolated static func levelCost(_ n: Int) -> Int { 100 + 50 * n }

    struct LevelInfo: Equatable, Sendable {
        var level: Int
        var xpIntoLevel: Int
        var levelCost: Int
        var xpToNext: Int { levelCost - xpIntoLevel }
        var fraction: Double { Double(xpIntoLevel) / Double(max(1, levelCost)) }
        var stage: BuddyStage { Progression.stage(forLevel: level) }
    }

    nonisolated static func levelInfo(totalXP: Int) -> LevelInfo {
        var level = 1, left = max(0, totalXP)
        while left >= levelCost(level) {
            left -= levelCost(level)
            level += 1
        }
        return LevelInfo(level: level, xpIntoLevel: left, levelCost: levelCost(level))
    }

    /// Egg 1 · Hatchling 2–4 · Sprout 5–9 · Adult 10–19 · Legend 20+.
    nonisolated static func stage(forLevel level: Int) -> BuddyStage {
        switch level {
        case ..<2: .egg
        case 2...4: .hatchling
        case 5...9: .sprout
        case 10...19: .adult
        default: .legend
        }
    }

    /// The first level of the next stage (nil at Legend).
    nonisolated static func nextStageLevel(after level: Int) -> Int? {
        [2, 5, 10, 20].first { $0 > level }
    }

    // MARK: - Form (mood only — never touches XP or level)

    struct Form: Equatable, Sendable {
        enum Basis: Equatable, Sendable {
            /// Planned sessions done ÷ planned, last 4 weeks.
            case plan(done: Int, planned: Int)
            /// Sessions a week lately vs your usual week.
            case usual(recentPerWeek: Double, usualPerWeek: Double)
            /// Nothing to go on yet.
            case new
        }
        var value: Double
        var basis: Basis
        /// Paused: Form is frozen at its value when the pause began.
        var held = false

        var summary: String {
            switch basis {
            case .plan(let d, let p): "\(d) of \(p) planned · 4 wks"
            case .usual(let r, let u):
                "\(String(format: "%.1f", r)) a week · usual \(String(format: "%.1f", u))"
            case .new: "Train to build Form"
            }
        }
    }

    /// `schedules` = routine id → schedule (enabled ones plan sessions). With at least two planned
    /// days in the last 4 weeks, Form is done ÷ planned (a day with a skipped slot is neutral, today
    /// only counts once it's done). Otherwise it compares the last 4 weeks with your usual week.
    /// Pauses: while one is running Form is held at its value when it began; afterwards, paused days
    /// are neutral (not planned, and not counted against your usual week).
    static func form(_ sessions: [WorkoutSession], schedules: [UUID: RoutineSchedule], pauses: [Pause] = [],
                     now: Date = .now, calendar: Calendar = .current) -> Form {
        if let p = activePause(pauses, now: now) {
            var f = form(sessions, schedules: schedules, pauses: pauses.filter { $0.id != p.id },
                         now: p.start, calendar: calendar)
            f.held = true
            return f
        }
        func paused(_ day: DayKey) -> Bool {
            let noon = day.date(calendar: calendar).addingTimeInterval(12 * 3_600)
            return pauses.contains { $0.covers(noon) }
        }
        let done = sessions.filter { $0.completedAt != nil }
        let today = DayKey(now, calendar: calendar)
        let start = today.adding(days: -27, calendar: calendar)

        var planned = 0, hit = 0
        for (routineID, schedule) in schedules where schedule.isEnabled {
            let doneDays = Set(done.filter { $0.routineID == routineID }.map { DayKey($0.startedAt, calendar: calendar) })
            var day = start
            while day <= today {
                defer { day = day.adding(days: 1, calendar: calendar) }
                // "Skip today" (a skipped day) or skipping one of several slots is neutral, not a miss.
                guard schedule.occurs(on: day, calendar: calendar), !schedule.skippedDays.contains(day),
                      !schedule.skippedSlots.contains(where: { $0.day == day }), !paused(day) else { continue }
                let wasDone = doneDays.contains(day)
                if day == today && !wasDone { continue }
                planned += 1
                if wasDone { hit += 1 }
            }
        }
        if planned >= 2 {
            return Form(value: Double(hit) / Double(planned), basis: .plan(done: hit, planned: planned))
        }

        let windowStart = start.date(calendar: calendar)
        let recent = done.filter { $0.startedAt >= windowStart && $0.startedAt <= now }.count
        guard let usualStart = calendar.date(byAdding: .day, value: -84, to: windowStart) else {
            return Form(value: 0.6, basis: .new)
        }
        let before = done.filter { $0.startedAt >= usualStart && $0.startedAt < windowStart }.count
        if recent == 0 && before == 0 { return Form(value: 0.6, basis: .new) }
        var pausedDays = 0
        var d = start
        while d <= today { if paused(d) { pausedDays += 1 }; d = d.adding(days: 1, calendar: calendar) }
        let recentPerWeek = Double(recent) / (Double(max(7, 28 - pausedDays)) / 7)
        let usual = Double(before) / 12
        // No usual week yet (new to Snappet): two sessions a week counts as full Form.
        let target = usual > 0 ? usual : 2
        return Form(value: min(1, recentPerWeek / target),
                    basis: .usual(recentPerWeek: recentPerWeek, usualPerWeek: usual > 0 ? usual : 2))
    }

    // MARK: - Overall week streak (any training) — see `streak(_:pauses:now:)` for freezes

    static func weekStreak(_ sessions: [WorkoutSession], pauses: [Pause] = [], now: Date = .now,
                           calendar: Calendar = .current) -> Int {
        streak(sessions, pauses: pauses, now: now, calendar: calendar).weeks
    }
}
