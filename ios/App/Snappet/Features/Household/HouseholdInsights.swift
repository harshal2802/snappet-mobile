import Foundation

/// The cooperative layer's numbers (household prompt 03), all derived from the folded board: the house
/// pet's XP and mood, the house streak, fair share and the weekly recap. Foundation only; XP values come
/// in as a closure so this stays free of the progression engine.
enum HouseholdInsights {

    // MARK: House pet

    /// Every credited member's chore XP, uncapped: the daily cap protects a person's level, not the house's.
    static func houseXP(_ board: ChoreBoard, before: Date = .distantFuture, calendar: Calendar = .current,
                        xp: (ChoreEffort) -> Int) -> Int {
        board.chores.values.reduce(0) { total, chore in
            total + board.rounds(of: chore, calendar: calendar).reduce(0) { sum, round in
                let credited = round.completions.filter { $0.at < before }
                return sum + Set(credited.map(\.member)).count * xp(chore.effort)
            }
        }
    }

    /// The pet's mood, 0…1, from the house's chore health: overdue chores (weighted by effort and days, a
    /// week at most) and, when there's a goal, the week's pace. Never about a person.
    static func mood(_ board: ChoreBoard, now: Date, calendar: Calendar = .current) -> Double {
        if board.isPaused(at: now, calendar: calendar) { return 0.6 }
        let pressure = overdue(board, now: now, calendar: calendar)
            .reduce(0.0) { $0 + Double($1.chore.effort.points * min($1.days, 7)) }
        // One large chore a day late ≈ 0.75 (still cosy); two chores three days late ≈ 0.38 (a bit neglected).
        let overdueHealth = 1 / (1 + pressure / 9)
        let start = ChoreSchedule.weekStart(now, calendar: calendar)
        guard let goal = board.goal(now: now, calendar: calendar), goal.target > 0 else {
            return min(1, max(0.05, overdueHealth))
        }
        let day = (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0) + 1
        let expected = Double(goal.target) * Double(min(7, max(1, day))) / 7
        let done = Double(board.roundsByDay(weekStart: start, calendar: calendar).reduce(0, +))
        let paceHealth = 0.4 + 0.6 * min(1, done / max(1, expected))
        return min(1, max(0.05, 0.65 * overdueHealth + 0.35 * paceHealth))
    }

    struct Overdue: Equatable, Sendable {
        var chore: Chore
        var days: Int
    }

    /// Overdue chores, most overdue first.
    static func overdue(_ board: ChoreBoard, now: Date, calendar: Calendar = .current) -> [Overdue] {
        board.activeChores.compactMap { chore in
            if case .due(let days) = board.status(of: chore, now: now, calendar: calendar), days > 0 {
                return Overdue(chore: chore, days: days)
            }
            return nil
        }
        .sorted { a, b in
            let wa = a.days * a.chore.effort.points, wb = b.days * b.chore.effort.points
            return wa != wb ? wa > wb : a.chore.name < b.chore.name
        }
    }

    /// "Cosy, the house is on top of things" … "Feeling neglected".
    static func moodTitle(_ mood: Double, paused: Bool) -> String {
        if paused { return "Dozing while you're away" }
        switch mood {
        case 0.75...: return "Cosy, the house is on top of things"
        case 0.5..<0.75: return "Content"
        case 0.3..<0.5: return "A bit neglected"
        default: return "Feeling neglected"
        }
    }

    /// "3 chores overdue · the kitchen's slipping": names a room, never a person.
    static func moodDetail(_ board: ChoreBoard, now: Date, calendar: Calendar = .current) -> String? {
        let late = overdue(board, now: now, calendar: calendar)
        guard !late.isEmpty else { return nil }
        let byRoom = Dictionary(grouping: late.filter { !$0.chore.room.isEmpty }, by: \.chore.room)
            .mapValues { $0.reduce(0) { $0 + $1.days * $1.chore.effort.points } }
        let count = late.count == 1 ? "1 chore overdue" : "\(late.count) chores overdue"
        let worst = byRoom.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
        guard let room = worst?.key else { return count }
        return "\(count) · the \(room.lowercased())'s slipping"
    }

    // MARK: House streak

    /// Consecutive weeks the house goal was met, ending this week (counted once met) or last week.
    /// A week mostly on pause (4+ days) is neutral: it neither breaks nor extends the streak.
    static func streak(_ board: ChoreBoard, now: Date, calendar: Calendar = .current) -> Int {
        let thisWeek = ChoreSchedule.weekStart(now, calendar: calendar)
        let earliest = board.chores.values.map(\.createdAt).min() ?? now
        var weeks = met(board, weekStart: thisWeek, calendar: calendar) ? 1 : 0
        var week = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        for _ in 0..<104 {
            guard calendar.date(byAdding: .day, value: 7, to: week).map({ $0 > earliest }) ?? false else { break }
            if met(board, weekStart: week, calendar: calendar) {
                weeks += 1
            } else if !mostlyPaused(board, weekStart: week, calendar: calendar) {
                break
            }
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        }
        return weeks
    }

    static func met(_ board: ChoreBoard, weekStart: Date, calendar: Calendar = .current) -> Bool {
        guard let goal = board.goals[ChoreSchedule.weekKey(weekStart, calendar: calendar)], goal.target > 0 else { return false }
        return board.roundsByDay(weekStart: weekStart, calendar: calendar).reduce(0, +) >= goal.target
    }

    static func mostlyPaused(_ board: ChoreBoard, weekStart: Date, calendar: Calendar = .current) -> Bool {
        let first = DayKey(weekStart, calendar: calendar)
        return (0..<7).filter { board.isPaused(day: first.adding(days: $0, calendar: calendar), calendar: calendar) }.count >= 4
    }

    // MARK: Fair share

    struct Share: Equatable, Sendable {
        var member: HouseholdMember
        var points: Int
        var fraction: Double
    }

    enum Balance: String, Equatable, Sendable {
        case balanced = "Balanced"
        case aBitUneven = "A bit uneven"
        case uneven = "Uneven"
    }

    /// Every member's effort points this week (including zero), in member order.
    static func fairShare(_ board: ChoreBoard, weekStart: Date, calendar: Calendar = .current) -> [Share] {
        let points = board.effortPoints(weekStart: weekStart, calendar: calendar)
        let total = max(1, points.values.reduce(0, +))
        return board.members.map { m in
            Share(member: m, points: points[m.id, default: 0], fraction: Double(points[m.id, default: 0]) / Double(total))
        }
    }

    /// Balanced when the biggest and smallest shares are within 10 percentage points; a bit uneven within 25.
    /// nil until there's something to compare (two members and some effort).
    static func balance(_ shares: [Share]) -> Balance? {
        guard shares.count > 1, shares.contains(where: { $0.points > 0 }) else { return nil }
        let fractions = shares.map(\.fraction)
        let spread = (fractions.max() ?? 0) - (fractions.min() ?? 0)
        if spread <= 0.10 + 1e-9 { return .balanced }
        if spread <= 0.25 + 1e-9 { return .aBitUneven }
        return .uneven
    }

    // MARK: Weekly recap

    struct Recap: Equatable, Sendable {
        struct Line: Equatable, Sendable {
            var member: HouseholdMember
            var text: String
        }
        var weekStart: Date
        var rounds: Int
        var goal: HouseholdGoal?
        var goalMet: Bool
        var levelBefore: Int
        var levelAfter: Int
        var lines: [Line]
        var thanks: [HouseholdThanks]
        var balanced: Bool
    }

    /// The week starting `weekStart`, told cooperatively: one line for each member who did something.
    static func recap(_ board: ChoreBoard, weekStart: Date, calendar: Calendar = .current,
                      xp: (ChoreEffort) -> Int, level: (Int) -> Int) -> Recap {
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let inWeek: (Date) -> Bool = { $0 >= weekStart && $0 < end }
        let goal = board.goals[ChoreSchedule.weekKey(weekStart, calendar: calendar)]
        let rounds = board.roundsByDay(weekStart: weekStart, calendar: calendar).reduce(0, +)
        let shares = fairShare(board, weekStart: weekStart, calendar: calendar)

        var lines: [Recap.Line] = []
        for member in board.members {
            if let text = bestLine(for: member, board: board, inWeek: inWeek, calendar: calendar) {
                lines.append(Recap.Line(member: member, text: text))
            }
        }
        return Recap(
            weekStart: weekStart, rounds: rounds, goal: goal,
            goalMet: (goal?.target ?? 0) > 0 && rounds >= (goal?.target ?? 0),
            levelBefore: level(houseXP(board, before: weekStart, calendar: calendar, xp: xp)),
            levelAfter: level(houseXP(board, before: end, calendar: calendar, xp: xp)),
            lines: lines,
            thanks: board.thanks.filter { inWeek($0.at) },
            balanced: balance(shares) == .balanced)
    }

    /// Took a help request › rescued an overdue chore › kept a daily chore going › did N chores.
    private static func bestLine(for member: HouseholdMember, board: ChoreBoard, inWeek: (Date) -> Bool,
                                 calendar: Calendar) -> String? {
        let mine = board.completions.filter { $0.member == member.id && inWeek($0.at) }
        guard !mine.isEmpty else { return nil }

        // 1. Took someone's help request.
        for c in mine {
            if let req = board.helpRequests.last(where: { $0.chore == c.chore && $0.member != member.id && $0.at <= c.at }),
               !board.completions.contains(where: { $0.chore == c.chore && $0.at >= req.at && $0.at < c.at }),
               let chore = board.chores[c.chore] {
                return "took \(board.name(of: req.member))'s \(chore.name.lowercased()) when they asked for a hand"
            }
        }
        // 2. Rescued an overdue "after done" chore (3+ days late).
        for c in mine {
            guard let chore = board.chores[c.chore], case .afterDone(let n) = chore.repeats else { continue }
            let prior = board.completions.last { $0.chore == c.chore && $0.at < c.at }?.at ?? chore.createdAt
            let due = DayKey(prior, calendar: calendar).adding(days: n, calendar: calendar)
            let late = calendar.dateComponents([.day], from: due.date(calendar: calendar),
                                               to: calendar.startOfDay(for: c.at)).day ?? 0
            if late >= 3 { return "finally did the \(chore.name.lowercased()) (\(late) days overdue)" }
        }
        // 3. A daily chore kept going 4+ days in a row (ending this week).
        var bestRun: (Int, String)?
        for chore in board.chores.values where chore.repeats == .daily {
            let days = Set(board.completions.filter { $0.chore == chore.id && $0.member == member.id }
                .map { DayKey($0.at, calendar: calendar) })
            for end in days where inWeek(end.date(calendar: calendar)) {
                var run = 1
                while days.contains(end.adding(days: -run, calendar: calendar)) { run += 1 }
                if run >= 4, run > (bestRun?.0 ?? 0) { bestRun = (run, chore.name) }
            }
        }
        if let (run, name) = bestRun { return "did the \(name.lowercased()) \(run) days in a row" }
        // 4. Just the count of rounds they were credited for.
        let credited = board.chores.values.reduce(0) { total, chore in
            total + board.rounds(of: chore, calendar: calendar).filter { round in
                inWeek(round.first.at) && round.members.contains(member.id)
            }.count
        }
        return credited == 1 ? "did 1 chore" : "did \(credited) chores"
    }
}
