import Foundation

// The Household mini-app's source of truth (household prompt 01): an append-only log of operations.
// Nothing stores "the board" — `ChoreBoard.fold` derives it — so one phone (P1) and many (P2) run the
// same code, and syncing is "swap version vectors, send the ops the other side is missing".
//
// The JSON form below is a cross-platform contract (P2 sends it, P4's Kotlin port parses it), specified
// in `pdd/context/household-wire-format.md` and pinned by golden tests. Changing it needs a version bump.
// Foundation only: no SwiftUI / SwiftData here.

enum ChoreEffort: String, Codable, CaseIterable, Sendable {
    case s, m, l

    /// Effort points: what the fair share (P3) weighs and what XP scales with.
    var points: Int {
        switch self {
        case .s: return 1
        case .m: return 2
        case .l: return 3
        }
    }

    var label: String { rawValue.uppercased() }

    var hint: String {
        switch self {
        case .s: return "5 min"
        case .m: return "20 min"
        case .l: return "45 min+"
        }
    }
}

/// How often a chore comes round.
enum ChoreRepeat: Equatable, Sendable {
    case daily
    /// `Calendar` weekdays (1 = Sunday … 7 = Saturday), resolved through `HabitSchedule`.
    case weekdays(Set<Int>)
    /// Once per calendar week, any day.
    case weekly
    /// Due `days` after the most recent completion by anyone; never done = due now.
    case afterDone(days: Int)
    case once
}

/// Who a chore falls to.
enum ChoreAssignment: Equatable, Sendable {
    /// Round-robin: each completed round passes it to the next member in this order.
    case rotate([UUID])
    case fixed(UUID)
    /// Anyone can claim it.
    case upForGrabs
}

/// A chore's editable fields. `nil` = not set by this op (an edit carries only what changed, which is
/// what makes per-field last-writer-wins possible).
struct ChoreFields: Equatable, Sendable {
    var name: String?
    var emoji: String?
    var room: String?
    var effort: ChoreEffort?
    var repeats: ChoreRepeat?
    var assignment: ChoreAssignment?
    /// Household prompt 03: a rotating chore goes to whoever in its rotation has done least this week.
    var lean: Bool?
}

struct ChoreOp: Identifiable, Equatable, Sendable {
    static let wireVersion = 1

    var id: UUID
    /// The phone that wrote it.
    var device: UUID
    /// Per-device counter, from 1. With `device`, what version vectors count.
    var seq: Int
    var at: Date
    var kind: Kind

    enum Kind: Equatable, Sendable {
        case addMember(member: UUID, name: String)
        case createChore(chore: UUID, fields: ChoreFields)
        case editChore(chore: UUID, fields: ChoreFields)
        case archiveChore(chore: UUID)
        case complete(chore: UUID, member: UUID)
        /// Retracts a `complete` or `claim`.
        case undo(op: UUID)
        case claim(chore: UUID, member: UUID)
        /// `week` = the week's first day, `yyyy-MM-dd`.
        case setGoal(week: String, target: Int, reward: String)
        /// Household prompt 02: the shared household name. Latest wins.
        case renameHousehold(name: String)
        /// Household prompt 03: "can someone take this?" Open until the chore is next done, someone
        /// else claims it, or it's undone.
        case askHelp(chore: UUID, member: UUID, note: String)
        /// A thank-you from `by` to `member`, optionally for a chore.
        case thank(member: UUID, by: UUID, chore: UUID?)
        /// The house on holiday from this op's time until `until` (yyyy-MM-dd, inclusive) or a resume.
        case pauseHouse(until: String?)
        case resumeHouse
        case namePet(name: String)
        /// A kind from a newer app version: kept in the log (and relayed), ignored by the fold.
        case unknown(String)
    }

    /// The total order every phone folds in: time, then device, then counter. Ties are impossible
    /// across devices and a device's own ops are ordered by `seq`.
    static func precedes(_ a: ChoreOp, _ b: ChoreOp) -> Bool {
        if a.at != b.at { return a.at < b.at }
        if a.device != b.device { return a.device.uuidString < b.device.uuidString }
        return a.seq < b.seq
    }
}

// MARK: - Version vectors

/// The highest `seq` seen per device. Two phones swap these and send each other what's missing.
struct VersionVector: Equatable, Sendable {
    var counters: [UUID: Int] = [:]

    init(_ ops: [ChoreOp] = []) {
        for op in ops { counters[op.device] = max(counters[op.device] ?? 0, op.seq) }
    }

    subscript(device: UUID) -> Int { counters[device] ?? 0 }

    /// The ops in `ops` that a peer at `self` hasn't seen.
    func missing(from ops: [ChoreOp]) -> [ChoreOp] {
        ops.filter { $0.seq > self[$0.device] }
    }
}

// MARK: - Wire format (v1)

extension ChoreOp {
    enum WireError: Error, Equatable {
        case unsupportedVersion(Int)
        case badDate(String)
    }

    /// One op as JSON: sorted keys, lowercase UUIDs, ISO-8601 UTC dates with milliseconds.
    func wireData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(self))
    }

    static func fromWire(_ data: Data) throws -> ChoreOp {
        try JSONDecoder().decode(Wire.self, from: data).decoded()
    }

    /// `2026-10-04T09:12:00.000Z`.
    static func formatDate(_ d: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(d)
    }

    /// Accepts the date with or without milliseconds.
    static func parseDate(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }
}

/// The flat JSON shape. Every kind shares one object; the fields a kind doesn't use are absent.
private struct Wire: Codable {
    var v: Int
    var id: String
    var device: String
    var seq: Int
    var at: String
    var kind: String
    var member: String?
    var name: String?
    var chore: String?
    var fields: WireFields?
    var op: String?
    var week: String?
    var target: Int?
    var reward: String?
    var note: String?
    var by: String?
    var until: String?

    init(_ o: ChoreOp) {
        v = ChoreOp.wireVersion
        id = o.id.wire
        device = o.device.wire
        seq = o.seq
        at = ChoreOp.formatDate(o.at)
        switch o.kind {
        case .addMember(let m, let n): kind = "add_member"; member = m.wire; name = n
        case .createChore(let c, let f): kind = "create_chore"; chore = c.wire; fields = WireFields(f)
        case .editChore(let c, let f): kind = "edit_chore"; chore = c.wire; fields = WireFields(f)
        case .archiveChore(let c): kind = "archive_chore"; chore = c.wire
        case .complete(let c, let m): kind = "complete"; chore = c.wire; member = m.wire
        case .undo(let target): kind = "undo"; op = target.wire
        case .claim(let c, let m): kind = "claim"; chore = c.wire; member = m.wire
        case .setGoal(let w, let t, let r): kind = "set_goal"; week = w; target = t; reward = r
        case .renameHousehold(let n): kind = "rename_household"; name = n
        case .askHelp(let c, let m, let n): kind = "ask_help"; chore = c.wire; member = m.wire; note = n
        case .thank(let m, let b, let c): kind = "thank"; member = m.wire; by = b.wire; chore = c?.wire
        case .pauseHouse(let u): kind = "pause_house"; until = u
        case .resumeHouse: kind = "resume_house"
        case .namePet(let n): kind = "name_pet"; name = n
        case .unknown(let k): kind = k
        }
    }

    func decoded() throws -> ChoreOp {
        guard v == ChoreOp.wireVersion else { throw ChoreOp.WireError.unsupportedVersion(v) }
        guard let date = ChoreOp.parseDate(at) else { throw ChoreOp.WireError.badDate(at) }
        let id = UUID(wire: self.id), device = UUID(wire: self.device)
        let choreID = UUID(wire: chore), memberID = UUID(wire: member)
        let k: ChoreOp.Kind
        switch kind {
        case "add_member": k = .addMember(member: memberID, name: name ?? "")
        case "create_chore": k = .createChore(chore: choreID, fields: fields?.value ?? ChoreFields())
        case "edit_chore": k = .editChore(chore: choreID, fields: fields?.value ?? ChoreFields())
        case "archive_chore": k = .archiveChore(chore: choreID)
        case "complete": k = .complete(chore: choreID, member: memberID)
        case "undo": k = .undo(op: UUID(wire: op))
        case "claim": k = .claim(chore: choreID, member: memberID)
        case "set_goal": k = .setGoal(week: week ?? "", target: target ?? 0, reward: reward ?? "")
        case "rename_household": k = .renameHousehold(name: name ?? "")
        case "ask_help": k = .askHelp(chore: choreID, member: memberID, note: note ?? "")
        case "thank": k = .thank(member: memberID, by: UUID(wire: by), chore: chore.flatMap(UUID.init(uuidString:)))
        case "pause_house": k = .pauseHouse(until: until)
        case "resume_house": k = .resumeHouse
        case "name_pet": k = .namePet(name: name ?? "")
        default: k = .unknown(kind)
        }
        return ChoreOp(id: id, device: device, seq: seq, at: date, kind: k)
    }
}

private struct WireFields: Codable {
    var name: String?
    var emoji: String?
    var room: String?
    var effort: String?
    var repeats: WireRepeat?
    var assignment: WireAssignment?
    var lean: Bool?

    init(_ f: ChoreFields) {
        name = f.name; emoji = f.emoji; room = f.room; effort = f.effort?.rawValue; lean = f.lean
        repeats = f.repeats.map(WireRepeat.init)
        assignment = f.assignment.map(WireAssignment.init)
    }

    /// Unknown effort / repeat / assignment values (a newer app's) drop just that field.
    var value: ChoreFields {
        ChoreFields(name: name, emoji: emoji, room: room, effort: effort.flatMap(ChoreEffort.init(rawValue:)),
                    repeats: repeats?.value, assignment: assignment?.value, lean: lean)
    }
}

private struct WireRepeat: Codable {
    var mode: String
    var days: [Int]?
    var every: Int?

    init(_ r: ChoreRepeat) {
        switch r {
        case .daily: mode = "daily"
        case .weekdays(let d): mode = "weekdays"; days = d.sorted()
        case .weekly: mode = "weekly"
        case .afterDone(let n): mode = "after_done"; every = n
        case .once: mode = "once"
        }
    }

    var value: ChoreRepeat? {
        switch mode {
        case "daily": return .daily
        case "weekdays": return .weekdays(Set((days ?? []).filter { (1...7).contains($0) }))
        case "weekly": return .weekly
        case "after_done": return .afterDone(days: max(1, every ?? 1))
        case "once": return .once
        default: return nil
        }
    }
}

private struct WireAssignment: Codable {
    var mode: String
    var members: [String]?
    var member: String?

    init(_ a: ChoreAssignment) {
        switch a {
        case .rotate(let order): mode = "rotate"; members = order.map(\.wire)
        case .fixed(let m): mode = "fixed"; member = m.wire
        case .upForGrabs: mode = "up_for_grabs"
        }
    }

    var value: ChoreAssignment? {
        switch mode {
        case "rotate": return .rotate((members ?? []).compactMap(UUID.init(uuidString:)))
        case "fixed": return member.flatMap(UUID.init(uuidString:)).map(ChoreAssignment.fixed)
        case "up_for_grabs": return .upForGrabs
        default: return nil
        }
    }
}

private extension UUID {
    var wire: String { uuidString.lowercased() }

    /// Missing or malformed ids become a fixed nil UUID, which matches no chore or member.
    init(wire: String?) {
        self = wire.flatMap(UUID.init(uuidString:)) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
