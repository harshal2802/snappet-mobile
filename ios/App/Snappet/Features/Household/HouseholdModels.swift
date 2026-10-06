import Foundation
import SwiftData

// Household persistence (household prompt 01). The log is the data: one row per op, holding the op's
// wire JSON verbatim, so an op from a newer app version survives untouched and can be relayed (P2).
// The board is never stored. Flat rows, plain-UUID FKs, inline defaults, no unique constraints (the
// suite's CloudKit-compatible shape). Rows ride `SnappetBackup` (same change; the tripwire enforces it).

/// This phone's household. P1 has exactly one, created on first open.
@Model
final class Household {
    var id: UUID = UUID()
    var name: String = "Our home"
    /// The id this phone writes ops under (version vectors count per device).
    var myDeviceID: UUID = UUID()
    /// The member this phone's user is in the log.
    var myMemberID: UUID = UUID()
    var createdAt: Date = Date()
    /// The household secret (32 bytes) members prove to each other when syncing (household prompt 02).
    /// Empty until the first invite; arrives in the welcome when joining. Never put in a QR or a URL.
    var key: Data = Data()
    /// Set when this phone joined another household: kept so its history and XP survive.
    var leftAt: Date?

    init(id: UUID = UUID(), name: String, myDeviceID: UUID = UUID(), myMemberID: UUID = UUID(),
         createdAt: Date = .now, key: Data = Data(), leftAt: Date? = nil) {
        self.id = id
        self.name = name
        self.myDeviceID = myDeviceID
        self.myMemberID = myMemberID
        self.createdAt = createdAt
        self.key = key
        self.leftAt = leftAt
    }
}

/// Another phone in the household, as last seen by a sync (household prompt 02, frame 5).
@Model
final class HouseholdPeer {
    var id: UUID = UUID()
    var householdID: UUID = UUID()
    var deviceID: UUID = UUID()
    var memberID: UUID?
    var name: String = ""
    var platform: String = ""
    var lastSyncedAt: Date = Date()
    /// The highest seq of this phone's own ops the peer has confirmed: what "changes waiting" counts from.
    var ackedSeq: Int = 0

    init(id: UUID = UUID(), householdID: UUID, deviceID: UUID, memberID: UUID?, name: String, platform: String,
         lastSyncedAt: Date = .now, ackedSeq: Int = 0) {
        self.id = id
        self.householdID = householdID
        self.deviceID = deviceID
        self.memberID = memberID
        self.name = name
        self.platform = platform
        self.lastSyncedAt = lastSyncedAt
        self.ackedSeq = ackedSeq
    }
}

/// One operation in a household's log. `opID`/`deviceID`/`seq`/`at` are denormalized from `payload`
/// for sorting and version vectors; `payload` is the source of truth.
@Model
final class HouseholdOpRecord {
    var id: UUID = UUID()
    var householdID: UUID = UUID()
    var opID: UUID = UUID()
    var deviceID: UUID = UUID()
    var seq: Int = 0
    var at: Date = Date()
    /// The op's v1 wire JSON.
    var payload: Data = Data()

    init(id: UUID = UUID(), householdID: UUID, opID: UUID, deviceID: UUID, seq: Int, at: Date, payload: Data) {
        self.id = id
        self.householdID = householdID
        self.opID = opID
        self.deviceID = deviceID
        self.seq = seq
        self.at = at
        self.payload = payload
    }

    convenience init(householdID: UUID, op: ChoreOp) throws {
        self.init(householdID: householdID, opID: op.id, deviceID: op.device, seq: op.seq, at: op.at,
                  payload: try op.wireData())
    }

    /// `nil` only for a damaged payload (or one from an unsupported wire version).
    var op: ChoreOp? { try? ChoreOp.fromWire(payload) }
}
