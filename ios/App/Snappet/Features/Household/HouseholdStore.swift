import Foundation
import SwiftData
import Observation

/// The thin SwiftData edge over the household log: loads the ops, folds them, appends new ops as this
/// phone, and (household prompt 02) ingests ops from other phones verbatim, remembers peers, and joins
/// households. All decisions live in `ChoreBoard` / `ChoreSchedule` / `HouseholdSyncMachine`.
///
/// One instance per app (`AppModel.householdStore()`), so a sync that lands while Household is open
/// redraws the board.
@MainActor
@Observable
final class HouseholdStore {
    private let context: ModelContext
    private(set) var household: Household
    private(set) var records: [HouseholdOpRecord] = []
    private(set) var ops: [ChoreOp] = []
    private(set) var board = ChoreBoard()
    private(set) var peers: [HouseholdPeer] = []
    /// XP from households this phone has left, folded once (their logs don't change).
    @ObservationIgnored private var formerEarnings: [Progression.Earning] = []
    /// Told after every local write, so the peer service can push it to phones in reach.
    @ObservationIgnored var onLocalChange: (() -> Void)?
    /// Told after every reload (any change, local or synced): the widget, watch and Live Activity follow.
    @ObservationIgnored var onReload: (() -> Void)?

    var me: UUID { household.myMemberID }
    var myDevice: UUID { household.myDeviceID }
    var displayName: String { board.householdName ?? household.name }
    var myName: String { board.members.first { $0.id == me }?.name ?? "You" }
    /// More than one member: the household is shared and worth syncing.
    var isShared: Bool { board.members.count > 1 }

    init(context: ModelContext) {
        self.context = context
        self.household = Self.active(context: context) ?? Self.create(context: context)
        formerEarnings = Self.formerEarnings(excluding: household.id, context: context)
        reload()
    }

    // MARK: Loading

    /// The household this phone uses: the newest one it hasn't left.
    static func active(context: ModelContext) -> Household? {
        let all = (try? context.fetch(FetchDescriptor<Household>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return all.first { $0.leftAt == nil }
    }

    /// A new household with its first member (you).
    private static func create(context: ModelContext, id: UUID = UUID(), name: String = "Our home",
                               key: Data = Data(), device: UUID = UUID(), member: UUID = UUID(),
                               myName: String = "You") -> Household {
        let h = Household(id: id, name: name, myDeviceID: device, myMemberID: member, key: key)
        context.insert(h)
        let first = ChoreOp(id: UUID(), device: h.myDeviceID, seq: 1, at: .now,
                            kind: .addMember(member: h.myMemberID, name: myName))
        if let record = try? HouseholdOpRecord(householdID: h.id, op: first) { context.insert(record) }
        try? context.save()
        return h
    }

    func reload() {
        let id = household.id
        records = (try? context.fetch(FetchDescriptor<HouseholdOpRecord>(predicate: #Predicate { $0.householdID == id }))) ?? []
        ops = records.compactMap(\.op)
        board = ChoreBoard.fold(ops)
        peers = ((try? context.fetch(FetchDescriptor<HouseholdPeer>(predicate: #Predicate { $0.householdID == id })))
                 ?? []).sorted { $0.lastSyncedAt > $1.lastSyncedAt }
        HouseholdXP.shared.publish(HouseholdXP.earnings(board: board, me: me) + formerEarnings)
        onReload?()
    }

    static func ops(for householdID: UUID, context: ModelContext) -> [ChoreOp] {
        let d = FetchDescriptor<HouseholdOpRecord>(predicate: #Predicate { $0.householdID == householdID })
        return ((try? context.fetch(d)) ?? []).compactMap(\.op)
    }

    private static func formerEarnings(excluding id: UUID, context: ModelContext) -> [Progression.Earning] {
        let all = (try? context.fetch(FetchDescriptor<Household>())) ?? []
        return all.filter { $0.id != id }.flatMap {
            HouseholdXP.earnings(board: ChoreBoard.fold(ops(for: $0.id, context: context)), me: $0.myMemberID)
        }
    }

    // MARK: Writing

    @discardableResult
    func append(_ kind: ChoreOp.Kind, at: Date = .now) -> ChoreOp {
        let op = writeOp(kind, at: at)
        reload()
        onLocalChange?()
        return op
    }

    private func writeOp(_ kind: ChoreOp.Kind, at: Date = .now) -> ChoreOp {
        let op = ChoreOp(id: UUID(), device: myDevice, seq: vector[myDevice] + 1, at: at, kind: kind)
        if let record = try? HouseholdOpRecord(householdID: household.id, op: op) {
            context.insert(record)
            records.append(record)
            try? context.save()
        }
        return op
    }

    func create(_ fields: ChoreFields) {
        append(.createChore(chore: UUID(), fields: fields))
    }

    /// Writes only the fields that changed, so a concurrent edit to another field survives a merge.
    func edit(_ chore: Chore, to fields: ChoreFields) {
        var changed = ChoreFields()
        if fields.name != chore.name { changed.name = fields.name }
        if fields.emoji != chore.emoji { changed.emoji = fields.emoji }
        if fields.room != chore.room { changed.room = fields.room }
        if fields.effort != chore.effort { changed.effort = fields.effort }
        if fields.repeats != chore.repeats { changed.repeats = fields.repeats }
        if fields.assignment != chore.assignment { changed.assignment = fields.assignment }
        if let lean = fields.lean, lean != chore.lean { changed.lean = lean }
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

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != displayName else { return }
        append(.renameHousehold(name: n))
    }

    func setMyName(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != myName else { return }
        append(.addMember(member: me, name: n))
    }

    // MARK: Ticks from the widget and the watch (household prompt 04)

    /// Applies ticks made away from the app, oldest first, as ops stamped with the tap's time. Idempotent:
    /// a tick for a chore I've already done in that round (or an untick of one I haven't) writes nothing.
    /// Returns the ids handled (applied or no-op), for the outbox to drop.
    @discardableResult
    func apply(_ toggles: [ChoreToggle], calendar: Calendar = .current) -> [UUID] {
        var handled: [UUID] = []
        var wrote = false
        for t in toggles.sorted(by: { $0.requestedAt < $1.requestedAt }) {
            handled.append(t.id)
            guard let chore = board.chores[t.choreID], !chore.archived else { continue }
            let at = min(t.requestedAt, .now)
            let round: ChoreRound?
            if case .done(let r) = board.status(of: chore, now: at, calendar: calendar) { round = r } else { round = nil }
            let mine = round?.completions.filter { $0.member == me } ?? []
            if t.desired, mine.isEmpty {
                _ = writeOp(.complete(chore: chore.id, member: me), at: at)
                wrote = true
            } else if !t.desired, !mine.isEmpty {
                for c in mine { _ = writeOp(.undo(op: c.opID), at: at) }
                wrote = true
            }
            if wrote { board = ChoreBoard.fold(records.compactMap(\.op)) }   // the next toggle sees this one
        }
        if wrote {
            reload()
            onLocalChange?()
        }
        return handled
    }

    // MARK: Power hour (household prompt 04)

    func startPowerHour(minutes: Int, target: Int, now: Date = .now) {
        append(.startPowerHour(ends: now.addingTimeInterval(TimeInterval(minutes * 60)), target: target), at: now)
    }

    func endPowerHour() { append(.endPowerHour) }

    // MARK: Cooperative (household prompt 03)

    var petName: String { board.petName ?? "Biscuit" }

    func askHelp(_ chore: Chore, note: String) {
        append(.askHelp(chore: chore.id, member: me, note: note.trimmingCharacters(in: .whitespaces)))
    }

    /// Takes back my own help request.
    func retractHelp(_ request: HelpRequest) {
        guard request.member == me else { return }
        append(.undo(op: request.opID))
    }

    func thank(_ member: UUID, for chore: UUID?) {
        guard member != me else { return }
        append(.thank(member: member, by: me, chore: chore))
    }

    func pauseHouse(until: DayKey? = nil) {
        append(.pauseHouse(until: until.map { String(format: "%04d-%02d-%02d", $0.value / 10_000, ($0.value / 100) % 100, $0.value % 100) }))
    }

    func resumeHouse() { append(.resumeHouse) }

    func namePet(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != petName else { return }
        append(.namePet(name: n))
    }

    // MARK: Sync (household prompt 02)

    /// Highest seq per device, from the stored rows (an op this app can't decode still counts).
    var vector: VersionVector {
        var v = VersionVector()
        for r in records { v.counters[r.deviceID] = max(v.counters[r.deviceID] ?? 0, r.seq) }
        return v
    }

    /// The stored payloads a peer at `theirs` hasn't seen, oldest first per device.
    func missingPayloads(for theirs: VersionVector) -> [String] {
        records.filter { $0.seq > theirs[$0.deviceID] }
            .sorted { ($0.deviceID.uuidString, $0.seq) < ($1.deviceID.uuidString, $1.seq) }
            .map { String(decoding: $0.payload, as: UTF8.self) }
    }

    /// Stores ops from another phone byte for byte (skipping ones already here), then folds once.
    @discardableResult
    func ingest(_ payloads: [String]) -> Int {
        var known = Set(records.map(\.opID))
        var added = 0
        for p in payloads {
            let data = Data(p.utf8)
            guard let op = try? ChoreOp.fromWire(data), known.insert(op.id).inserted else { continue }
            let record = HouseholdOpRecord(householdID: household.id, opID: op.id, deviceID: op.device,
                                           seq: op.seq, at: op.at, payload: data)
            context.insert(record)
            added += 1
        }
        if added > 0 {
            try? context.save()
            reload()
        }
        return added
    }

    var syncLog: HouseholdSyncMachine.Log {
        HouseholdSyncMachine.Log(vector: { [unowned self] in vector },
                                 missing: { [unowned self] in missingPayloads(for: $0) },
                                 ingest: { [unowned self] in ingest($0) })
    }

    var identity: HouseholdSyncMachine.Identity {
        HouseholdSyncMachine.Identity(device: myDevice, member: me, name: myName)
    }

    /// The household secret, made on first use (the first invite).
    @discardableResult
    func ensureKey() -> Data {
        if household.key.count != 32 {
            household.key = HouseholdCrypto.randomBytes(32)
            try? context.save()
        }
        return household.key
    }

    var tag: String? {
        household.key.count == 32 ? HouseholdCrypto.tag(secret: household.key, label: HouseholdCrypto.householdTagLabel) : nil
    }

    func recordSync(_ summary: HouseholdSyncMachine.Summary, now: Date = .now) {
        let peerDevice = summary.peer.device
        let peer = peers.first { $0.deviceID == peerDevice } ?? {
            let p = HouseholdPeer(householdID: household.id, deviceID: peerDevice, memberID: summary.peer.member,
                                  name: summary.peer.name, platform: summary.peer.platform)
            context.insert(p)
            return p
        }()
        peer.memberID = summary.peer.member ?? peer.memberID
        if !summary.peer.name.isEmpty { peer.name = summary.peer.name }
        if !summary.peer.platform.isEmpty { peer.platform = summary.peer.platform }
        peer.lastSyncedAt = now
        peer.ackedSeq = max(peer.ackedSeq, summary.ackedSeq)
        try? context.save()
        reload()
    }

    /// My ops no peer has confirmed yet (frame 6's "2 changes waiting"). 0 with no peers.
    var changesWaiting: Int {
        guard !peers.isEmpty else { return 0 }
        return max(0, vector[myDevice] - (peers.map(\.ackedSeq).max() ?? 0))
    }

    var lastSyncedAt: Date? { peers.map(\.lastSyncedAt).max() }

    /// Join another household from its welcome: this one is kept (left) so its history and XP survive;
    /// `bringChores` copies its active chores across as new chores. Returns the joined household's log for
    /// the rest of the sync.
    func join(_ welcome: HouseholdWelcome, as me: HouseholdSyncMachine.Identity,
              bringChores: Bool) -> HouseholdSyncMachine.Log {
        let carried = bringChores ? board.activeChores : []
        household.leftAt = .now
        let name = me.name.trimmingCharacters(in: .whitespaces).isEmpty ? "You" : me.name
        household = Self.create(context: context, id: welcome.householdID, name: welcome.name, key: welcome.key,
                                device: me.device, member: me.member, myName: name)
        reload()   // so the counter below continues from the new household's first op
        for chore in carried {
            _ = writeOp(.createChore(chore: UUID(), fields: ChoreFields(
                name: chore.name, emoji: chore.emoji, room: chore.room, effort: chore.effort,
                repeats: chore.repeats, assignment: chore.assignment.carried(to: household.myMemberID))))
        }
        formerEarnings = Self.formerEarnings(excluding: household.id, context: context)
        reload()
        return syncLog
    }

    /// After a backup restore: a fresh device id per household, so two phones restored from one backup
    /// never write ops under the same device and counter.
    static func rerollDevices(context: ModelContext) {
        for h in (try? context.fetch(FetchDescriptor<Household>())) ?? [] { h.myDeviceID = UUID() }
        try? context.save()
    }
}

private extension ChoreAssignment {
    /// Members of the old household mean nothing in the new one: a carried chore is mine or up for grabs.
    func carried(to me: UUID) -> ChoreAssignment {
        switch self {
        case .upForGrabs: return .upForGrabs
        case .rotate, .fixed: return .rotate([me])
        }
    }
}

/// Chore XP for the buddy (household prompt 01): the completions credited to you, as XP earnings the
/// progression ledger folds in under the shared daily cap. Kept current by `HouseholdStore` and loaded
/// at launch by `RootShell`, so every ledger call (Home, the buddy, history, widgets) sees the same XP.
/// Observable, so a view whose body read it re-renders when a chore is ticked. Prompt 02: summed across
/// every household this phone has been in, so joining another keeps your old chores' XP.
@MainActor
@Observable
final class HouseholdXP {
    static let shared = HouseholdXP()
    private(set) var earnings: [Progression.Earning] = []

    func publish(_ next: [Progression.Earning]) {
        if next != earnings { earnings = next }
    }

    func publish(board: ChoreBoard, me: UUID) {
        publish(Self.earnings(board: board, me: me))
    }

    static func earnings(board: ChoreBoard, me: UUID, calendar: Calendar = .current) -> [Progression.Earning] {
        board.credits(for: me, calendar: calendar).map { credit in
            Progression.Earning(id: credit.opID, at: credit.at,
                                items: [Progression.XPItem(label: "\(credit.chore.emoji) \(credit.chore.name)",
                                                           xp: Progression.Rules.choreXP(credit.chore.effort))])
        }
    }

    /// Launch / after a restore: fold every stored household without creating one (a phone that never
    /// opened Household earns nothing and gets no rows).
    func load(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Household>())) ?? []
        publish(all.flatMap {
            Self.earnings(board: ChoreBoard.fold(HouseholdStore.ops(for: $0.id, context: context)), me: $0.myMemberID)
        })
    }
}
