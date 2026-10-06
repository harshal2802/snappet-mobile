import Foundation
import SwiftData
import Observation

/// The thin SwiftData edge over the household log: loads the ops, folds them (cached on the log's
/// size + last op), and appends new ops as this phone. All decisions live in `ChoreBoard` /
/// `ChoreSchedule`; this only reads, writes and republishes chore XP.
@MainActor
@Observable
final class HouseholdStore {
    private let context: ModelContext
    private(set) var household: Household
    private(set) var ops: [ChoreOp] = []
    private(set) var board = ChoreBoard()

    var me: UUID { household.myMemberID }

    init(context: ModelContext) {
        self.context = context
        self.household = Self.loadOrCreate(context: context)
        reload()
    }

    /// The one household, created with its first member (you) on first open.
    private static func loadOrCreate(context: ModelContext) -> Household {
        var d = FetchDescriptor<Household>(sortBy: [SortDescriptor(\.createdAt)])
        d.fetchLimit = 1
        if let existing = try? context.fetch(d).first { return existing }
        let h = Household(name: "Our home")
        context.insert(h)
        let first = ChoreOp(id: UUID(), device: h.myDeviceID, seq: 1, at: .now,
                            kind: .addMember(member: h.myMemberID, name: "You"))
        if let record = try? HouseholdOpRecord(householdID: h.id, op: first) { context.insert(record) }
        try? context.save()
        return h
    }

    func reload() {
        ops = Self.ops(for: household.id, context: context)
        board = ChoreBoard.fold(ops)
        HouseholdXP.shared.publish(board: board, me: me)
    }

    static func ops(for householdID: UUID, context: ModelContext) -> [ChoreOp] {
        let d = FetchDescriptor<HouseholdOpRecord>(predicate: #Predicate { $0.householdID == householdID })
        return ((try? context.fetch(d)) ?? []).compactMap(\.op)
    }

    // MARK: Writing

    @discardableResult
    func append(_ kind: ChoreOp.Kind, at: Date = .now) -> ChoreOp {
        let seq = VersionVector(ops)[household.myDeviceID] + 1
        let op = ChoreOp(id: UUID(), device: household.myDeviceID, seq: seq, at: at, kind: kind)
        if let record = try? HouseholdOpRecord(householdID: household.id, op: op) {
            context.insert(record)
            try? context.save()
        }
        reload()
        return op
    }

    func create(_ fields: ChoreFields) {
        append(.createChore(chore: UUID(), fields: fields))
    }

    /// Writes only the fields that changed, so a concurrent edit to another field survives (P2).
    func edit(_ chore: Chore, to fields: ChoreFields) {
        var changed = ChoreFields()
        if fields.name != chore.name { changed.name = fields.name }
        if fields.emoji != chore.emoji { changed.emoji = fields.emoji }
        if fields.room != chore.room { changed.room = fields.room }
        if fields.effort != chore.effort { changed.effort = fields.effort }
        if fields.repeats != chore.repeats { changed.repeats = fields.repeats }
        if fields.assignment != chore.assignment { changed.assignment = fields.assignment }
        guard changed != ChoreFields() else { return }
        append(.editChore(chore: chore.id, fields: changed))
    }

    func archive(_ chore: Chore) { append(.archiveChore(chore: chore.id)) }

    func complete(_ chore: Chore) { append(.complete(chore: chore.id, member: me)) }

    /// Untick: retracts my ticks of the current round.
    func uncomplete(_ chore: Chore, now: Date = .now) {
        guard case .done(let round) = board.status(of: chore, now: now) else { return }
        for c in round.completions where c.member == me { append(.undo(op: c.opID)) }
    }

    func claim(_ chore: Chore) { append(.claim(chore: chore.id, member: me)) }

    func setGoal(target: Int, reward: String, now: Date = .now) {
        append(.setGoal(week: ChoreSchedule.weekKey(now), target: target, reward: reward))
    }
}

/// Chore XP for the buddy (household prompt 01): the completions credited to you, as XP earnings the
/// progression ledger folds in under the shared daily cap. Kept current by `HouseholdStore` and loaded
/// at launch by `RootShell`, so every ledger call (Home, the buddy, history, widgets) sees the same XP.
/// Observable, so a view whose body read it re-renders when a chore is ticked.
@MainActor
@Observable
final class HouseholdXP {
    static let shared = HouseholdXP()
    private(set) var earnings: [Progression.Earning] = []

    func publish(board: ChoreBoard, me: UUID) {
        let next = Self.earnings(board: board, me: me)
        if next != earnings { earnings = next }
    }

    static func earnings(board: ChoreBoard, me: UUID, calendar: Calendar = .current) -> [Progression.Earning] {
        board.credits(for: me, calendar: calendar).map { credit in
            Progression.Earning(id: credit.opID, at: credit.at,
                                items: [Progression.XPItem(label: "\(credit.chore.emoji) \(credit.chore.name)",
                                                           xp: Progression.Rules.choreXP(credit.chore.effort))])
        }
    }

    /// Launch: fold the stored log without creating a household (a phone that never opened Household
    /// earns nothing and gets no rows).
    func load(context: ModelContext) {
        guard let h = try? context.fetch(FetchDescriptor<Household>()).first else {
            if !earnings.isEmpty { earnings = [] }
            return
        }
        publish(board: ChoreBoard.fold(HouseholdStore.ops(for: h.id, context: context)), me: h.myMemberID)
    }
}
