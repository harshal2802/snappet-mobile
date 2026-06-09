import Foundation
import CryptoKit

/// Deterministic, content-addressed identity for a climb the user *authors* on this device (the manual
/// editor or the on-device generator), kept platform-free and pure so it's unit-tested without a device.
///
/// The brief: *"a climb generated on two different devices must still be recognizably the same climb by
/// its uuid."* A literal time-based UUID (v1/v7) can't do that — it embeds the wall clock and a per-device
/// node, so two devices that design the identical problem get *different* ids. The only function that
/// returns the *same* id for the *same* holds, on every device, every time, is one derived purely from
/// the climb's content. So a created climb's uuid is a **UUIDv5** (RFC 4122, SHA-1 namespaced) over the
/// climb's *canonical* hold set. Creation time is recorded separately (`KilterCreatedClimb.createdAt`)
/// for ordering — never folded into the identity, which would break cross-device equality.
///
/// Two devices generating the same climb therefore converge on one uuid → the duplicate check can dedupe
/// *created* climbs by uuid alone. (Catalog climbs keep Aurora's own random uuids, so a created climb that
/// happens to match a *catalog* climb is caught by comparing canonical frames, not by uuid — see
/// `KilterDuplicateChecker`.)
enum KilterClimbIdentity {
    /// Fixed namespace for Snappet-authored Kilter climbs. Constant forever — changing it would re-key
    /// every previously-created climb, so it must never move. (A random v4 UUID, chosen once.)
    static let namespace = UUID(uuidString: "5F6B9D2E-1C4A-4B7E-9F3C-8A2D6E1B0C44")!

    /// Canonicalize a `p<placement>r<role>` frames string: parse → sort `(placementId, roleId)` ascending
    /// → re-serialize. Order-independent, so two devices that place the same holds in any order produce
    /// the same string (the basis for both the uuid and duplicate detection). Drops malformed tokens via
    /// the shared `KilterCatalog.parseFrames`.
    static func canonicalFrames(_ frames: String) -> String {
        let pairs: [(Int, Int)] = KilterCatalog.parseFrames(frames)
        let sorted = pairs.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let tokens: [String] = sorted.map { "p\($0.0)r\($0.1)" }
        return tokens.joined()
    }

    /// The layout-scoped identity key: `"<layoutId>:<canonicalFrames>"`. Layout-scoped because a
    /// `placement_id` is meaningful only within its layout — the same number is a different hole on a
    /// different board — matching Aurora's own notion of climb identity (`layout_id` + `frames`).
    static func canonicalKey(layoutId: Int, frames: String) -> String {
        "\(layoutId):\(canonicalFrames(frames))"
    }

    /// The deterministic content uuid for a created climb: UUIDv5 of the canonical key under the Snappet
    /// namespace. Same `(layout, holds)` → same uuid on every device. Formatted lowercase dashed to match
    /// the catalog's uuid shape (so a created climb is a drop-in `KilterClimb`).
    static func uuid(forLayout layoutId: Int, frames: String) -> String {
        uuidV5(namespace: namespace, name: canonicalKey(layoutId: layoutId, frames: frames))
    }

    /// RFC 4122 §4.3 name-based UUIDv5: SHA-1 over (namespace bytes ‖ name), first 16 bytes, with the
    /// version (5) and variant (RFC 4122) bits stamped in.
    static func uuidV5(namespace: UUID, name: String) -> String {
        var input = [UInt8]()
        input.reserveCapacity(16 + name.utf8.count)
        input.append(contentsOf: bytes(of: namespace))
        input.append(contentsOf: Array(name.utf8))

        var u = Array(Insecure.SHA1.hash(data: Data(input)).prefix(16))
        u[6] = (u[6] & 0x0F) | 0x50   // version 5
        u[8] = (u[8] & 0x3F) | 0x80   // variant 10xx (RFC 4122)
        return format(u)
    }

    /// The 16 raw bytes of a `UUID` (its `uuid` tuple), in order.
    private static func bytes(of uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// Lowercase 8-4-4-4-12 hex (the catalog's uuid form).
    private static func format(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return String(s[0..<8]) + "-" + String(s[8..<12]) + "-" + String(s[12..<16])
             + "-" + String(s[16..<20]) + "-" + String(s[20..<32])
    }
}
