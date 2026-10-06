import Foundation
import CryptoKit

// The household sync protocol's building blocks (household prompt 02), specified in
// `pdd/context/household-wire-format.md` § Sync protocol. Built from primitives every platform has
// (HKDF-SHA256, HMAC-SHA256, ChaCha20-Poly1305) rather than TLS-PSK, which Android's TLS stack doesn't
// expose to apps. No networking here: `HouseholdSyncMachine` drives these, `HouseholdPeerService` moves bytes.

enum HouseholdCrypto {
    static let householdTagLabel = "snappet-household-tag-v1"
    static let inviteTagLabel = "snappet-household-invite-v1"
    static let dialerToListener = "snappet-hh-v1 d2l"
    static let listenerToDialer = "snappet-hh-v1 l2d"

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// First 8 bytes of `HMAC-SHA256(secret, label)`, hex. Published in Bonjour TXT records so members
    /// recognise each other without the household id or key being visible on the network.
    static func tag(secret: Data, label: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: secret))
        return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    struct SessionKeys {
        var send: SymmetricKey
        var receive: SymmetricKey
    }

    /// Per-session keys: `HKDF-SHA256(ikm: secret, salt: dialerNonce ‖ listenerNonce, info: direction)`.
    static func sessionKeys(secret: Data, dialerNonce: Data, listenerNonce: Data, isDialer: Bool) -> SessionKeys {
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: dialerNonce + listenerNonce,
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        let d2l = derive(dialerToListener), l2d = derive(listenerToDialer)
        return isDialer ? SessionKeys(send: d2l, receive: l2d) : SessionKeys(send: l2d, receive: d2l)
    }

    /// `nonce(12) ‖ ciphertext ‖ tag(16)`.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    static func open(_ box: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: box), using: key)
    }
}

/// Length-prefixed frames: a 4-byte big-endian length, then that many bytes.
enum HouseholdFrame {
    static let maxLength = 1 << 20

    static func encode(_ payload: Data) -> Data {
        var n = UInt32(payload.count).bigEndian
        return Data(bytes: &n, count: 4) + payload
    }

    enum ReadError: Error, Equatable { case tooLarge(Int) }

    /// Accumulates bytes as they arrive (split or coalesced) and yields whole payloads.
    struct Reader {
        private var buffer = Data()

        mutating func push(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var out: [Data] = []
            while buffer.count >= 4 {
                let b = [UInt8](buffer.prefix(4))
                let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
                guard length <= HouseholdFrame.maxLength else { throw ReadError.tooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                out.append(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return out
        }
    }
}

/// Every message in the conversation, as one flat JSON object keyed by `t`.
struct HouseholdSyncMessage: Codable, Equatable, Sendable {
    var t: String
    var v: Int?
    var mode: String?
    var device: String?
    var nonce: String?
    var member: String?
    var name: String?
    var platform: String?
    var vv: [String: Int]?
    var ops: [String]?
    var household: String?
    var key: String?
    var reason: String?

    static func hello(mode: String?, device: UUID, nonce: Data) -> Self {
        Self(t: "hello", v: 1, mode: mode, device: device.uuidString.lowercased(), nonce: nonce.base64EncodedString())
    }
    static func auth(device: UUID) -> Self { Self(t: "auth", device: device.uuidString.lowercased()) }
    static func state(_ vv: VersionVector, member: UUID, name: String) -> Self {
        Self(t: "state", member: member.uuidString.lowercased(), name: name, platform: "ios",
             vv: Dictionary(uniqueKeysWithValues: vv.counters.map { ($0.key.uuidString.lowercased(), $0.value) }))
    }
    static func ops(_ payloads: [String]) -> Self { Self(t: "ops", ops: payloads) }
    static let done = Self(t: "done")
    static func welcome(_ w: HouseholdWelcome) -> Self {
        Self(t: "welcome", name: w.name, household: w.householdID.uuidString.lowercased(), key: w.key.base64EncodedString())
    }
    static func reject(_ reason: String) -> Self { Self(t: "reject", reason: reason) }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }

    var vector: VersionVector {
        var v = VersionVector()
        for (k, n) in vv ?? [:] { if let id = UUID(uuidString: k) { v.counters[id] = n } }
        return v
    }
}

/// What an inviter hands a joiner once the token checks out.
struct HouseholdWelcome: Equatable, Sendable {
    var householdID: UUID
    var name: String
    var key: Data
}
