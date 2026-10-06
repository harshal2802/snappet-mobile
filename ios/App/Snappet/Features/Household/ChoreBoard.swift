import Foundation

/// A chore as the log currently has it.
struct Chore: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String = "Chore"
    var emoji: String = "🧹"
    var room: String = ""
    var effort: ChoreEffort = .s
    var repeats: ChoreRepeat = .weekly
    var assignment: ChoreAssignment = .upForGrabs
    var createdAt: Date
    var archived = false
}

struct ChoreCompletion: Equatable, Sendable {
    var opID: UUID
    var chore: UUID
    var member: UUID
    var at: Date
}

struct HouseholdGoal: Equatable, Sendable {
    /// The week's first day, `yyyy-MM-dd`.
    var week: String
    /// Chores (rounds, not ticks) the household is aiming for this week.
    var target: Int
    var reward: String
}

struct HouseholdMember: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
}

/// The board, folded from the log. Order-independent and idempotent: any permutation or duplication
/// of the same ops folds to the same board, which is what lets phones exchange ops in any order (P2).
///
/// Merge rules (decided in P1 so P2 is plumbing):
/// - Chore fields are last-writer-wins **per field**, in `ChoreOp.precedes` order. A create is the base
///   even if a clock-skewed edit carries an earlier time.
/// - Archive is sticky: it beats any concurrent edit.
/// - Two members completing the same round (e.g. while apart) are both credited; the house goal
///   counts the round once. See `rounds(of:)`.
struct ChoreBoard: Equatable, Sendable {
    var members: [HouseholdMember] = []
    var chores: [UUID: Chore] = [:]
    /// Live completions (undone ones removed), oldest first. Archived chores keep theirs for history.
    var completions: [ChoreCompletion] = []
    /// Latest live claim per chore.
    var claims: [UUID: ChoreCompletion] = [:]
    var goals: [String: HouseholdGoal] = [:]
    /// The shared household name, if anyone has set one (household prompt 02).
    var householdName: String?

    static func fold(_ ops: [ChoreOp]) -> ChoreBoard {
        var seen = Set<UUID>()
        let sorted = ops.filter { seen.insert($0.id).inserted }.sorted(by: ChoreOp.precedes)
        let undone = Set(sorted.compactMap { op -> UUID? in
            if case .undo(let target) = op.kind { return target } else { return nil }
        })

        var board = ChoreBoard()
        var archived = Set<UUID>()
        var memberOrder: [UUID] = []
        var memberNames: [UUID: String] = [:]

        // Creates first, so an edit with a skewed-early clock still lands on top of its create.
        for op in sorted {
            if case .createChore(let id, let fields) = op.kind, board.chores[id] == nil {
                var chore = Chore(id: id, createdAt: op.at)
                chore.apply(fields)
                board.chores[id] = chore
            }
        }
        for op in sorted {
            switch op.kind {
            case .addMember(let id, let name):
                if memberNames[id] == nil { memberOrder.append(id) }
                memberNames[id] = name
            case .editChore(let id, let fields):
                board.chores[id]?.apply(fields)
            case .archiveChore(let id):
                archived.insert(id)
            case .complete(let chore, let member):
                guard !undone.contains(op.id), board.chores[chore] != nil else { continue }
                board.completions.append(ChoreCompletion(opID: op.id, chore: chore, member: member, at: op.at))
            case .claim(let chore, let member):
                guard !undone.contains(op.id), board.chores[chore] != nil else { continue }
                board.claims[chore] = ChoreCompletion(opID: op.id, chore: chore, member: member, at: op.at)
            case .setGoal(let week, let target, let reward):
                board.goals[week] = HouseholdGoal(week: week, target: max(0, target), reward: reward)
            case .renameHousehold(let name):
                if !name.isEmpty { board.householdName = name }
            case .createChore, .undo, .unknown:
                continue
            }
        }
        for id in archived { board.chores[id]?.archived = true }
        board.members = memberOrder.map { HouseholdMember(id: $0, name: memberNames[$0] ?? "") }
        return board
    }

    var activeChores: [Chore] {
        chores.values.filter { !$0.archived }.sorted {
            ($0.room, $0.name, $0.id.uuidString) < ($1.room, $1.name, $1.id.uuidString)
        }
    }

    func name(of member: UUID) -> String {
        members.first { $0.id == member }?.name ?? "Someone"
    }
}

private extension Chore {
    mutating func apply(_ f: ChoreFields) {
        if let v = f.name { name = v }
        if let v = f.emoji { emoji = v }
        if let v = f.room { room = v }
        if let v = f.effort { effort = v }
        if let v = f.repeats { repeats = v }
        if let v = f.assignment { assignment = v }
    }
}

// MARK: - Rounds, status, assignment

/// One time round of a chore: the completions that satisfied it. `members` are all credited; the
/// round counts once toward the house goal, on the day it was first done.
struct ChoreRound: Equatable, Sendable {
    var chore: UUID
    var completions: [ChoreCompletion]
    var first: ChoreCompletion { completions[0] }
    var members: [UUID] {
        var seen = Set<UUID>()
        return completions.map(\.member).filter { seen.insert($0).inserted }
    }
}

enum ChoreStatus: Equatable, Sendable {
    /// Needs doing. `overdueDays` > 0 only for "after done" chores past their date.
    case due(overdueDays: Int)
    /// This round is done; `round.first` is when.
    case done(ChoreRound)
    /// Not due today; `next` is the next day it is (nil = never again, for a finished one-off).
    case notDue(next: DayKey?)
}

/// A completion credited to a member: what XP is paid on. One per member per round.
struct ChoreCredit: Equatable, Sendable {
    var opID: UUID
    var at: Date
    var chore: Chore
}

extension ChoreBoard {
    /// The chore's completions grouped into rounds, oldest first.
    func rounds(of chore: Chore, calendar: Calendar = .current) -> [ChoreRound] {
        let mine = completions.filter { $0.chore == chore.id }
        var rounds: [ChoreRound] = []
        for c in mine {
            if let last = rounds.last,
               ChoreSchedule.sameRound(last.first.at, c.at, repeats: chore.repeats, calendar: calendar) {
                rounds[rounds.count - 1].completions.append(c)
            } else {
                rounds.append(ChoreRound(chore: chore.id, completions: [c]))
            }
        }
        return rounds
    }

    func status(of chore: Chore, now: Date, calendar: Calendar = .current) -> ChoreStatus {
        ChoreSchedule.status(repeats: chore.repeats, rounds: rounds(of: chore, calendar: calendar),
                             latest: completions.last { $0.chore == chore.id }?.at, now: now, calendar: calendar)
    }

    /// Who the current round falls to (the round just finished, if it's done). `nil` = up for grabs
    /// and unclaimed.
    func assignee(of chore: Chore, now: Date, calendar: Calendar = .current) -> UUID? {
        let rounds = rounds(of: chore, calendar: calendar)
        switch chore.assignment {
        case .fixed(let m):
            return m
        case .rotate(let order):
            guard !order.isEmpty else { return nil }
            let doneNow: Bool
            if case .done = status(of: chore, now: now, calendar: calendar) { doneNow = true } else { doneNow = false }
            let index = doneNow ? rounds.count - 1 : rounds.count
            return order[max(0, index) % order.count]
        case .upForGrabs:
            guard let claim = claims[chore.id] else { return nil }
            // A claim lasts until the chore is next done.
            if let last = completions.last(where: { $0.chore == chore.id }), last.at >= claim.at { return nil }
            return claim.member
        }
    }

    /// Every completion `member` is credited for: their first tick in each round.
    func credits(for member: UUID, calendar: Calendar = .current) -> [ChoreCredit] {
        chores.values.flatMap { chore in
            rounds(of: chore, calendar: calendar).compactMap { round in
                round.completions.first { $0.member == member }
                    .map { ChoreCredit(opID: $0.opID, at: $0.at, chore: chore) }
            }
        }
        .sorted { $0.at < $1.at }
    }

    /// Rounds first completed in the week starting `weekStart`, by day (7 counts, week order).
    func roundsByDay(weekStart: Date, calendar: Calendar = .current) -> [Int] {
        var counts = Array(repeating: 0, count: 7)
        for chore in chores.values {
            for round in rounds(of: chore, calendar: calendar) {
                let day = calendar.dateComponents([.day], from: weekStart,
                                                  to: calendar.startOfDay(for: round.first.at)).day ?? -1
                if (0..<7).contains(day) { counts[day] += 1 }
            }
        }
        return counts
    }

    /// The goal for the week containing `now`, if one is set.
    func goal(now: Date, calendar: Calendar = .current) -> HouseholdGoal? {
        goals[ChoreSchedule.weekKey(now, calendar: calendar)]
    }
}
