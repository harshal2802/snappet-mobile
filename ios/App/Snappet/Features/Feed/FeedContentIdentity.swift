import Foundation

// MARK: - Recap Feed — pure UUIDv5 content identity (F0b)
//
// Stable, cross-device content identity for feed activities. Pure (no SwiftData/UIKit),
// so the Kotlin port (FA0b) reproduces it verbatim. Namespaces are PINNED FOREVER —
// changing one re-keys every previously-derived identity. Inputs are canonicalized and
// built from SHARED FIELDS ONLY (never the Android-unstable autoincrement row id), so the
// same logical event yields the same `contentId` on iOS and Android (cross-device dedup).
//
// Reuses the repo's RFC-4122 §4.3 UUIDv5 helper (`KilterClimbIdentity.uuidV5`) — one
// SHA-1 implementation, already golden-vector tested.

enum FeedContentIdentity {

    // Pinned per-type namespaces — NEVER change.
    static let nsFeedItem = UUID(uuidString: "B3E1F4A2-6C70-4D58-9A11-2F8E5C0D7A31")!
    static let nsSession  = UUID(uuidString: "C7A2D9E4-1B83-4F26-8E55-3A6D0B1C9F42")!
    static let nsClimb    = UUID(uuidString: "D1F6B0C3-9E27-4A85-B642-7C3E8D2A5B16")!
    static let nsClip     = UUID(uuidString: "E5C8A1D7-2F34-4B90-9D18-6B4A0E7C2D53")!

    // MARK: Canonicalization (must be byte-identical to the FA0b Kotlin port)

    /// Trim + unicode-normalize (NFC) so two encodings of the same text hash identically.
    static func canon(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// A fixed-unit difficulty token (3 decimals) so float formatting can't diverge across platforms.
    static func fixed(_ d: Double) -> String { String(format: "%.3f", d) }

    /// UTC day bucket `yyyy-MM-dd` — computed without a stored DateFormatter (Sendable-safe, deterministic).
    static func dayBucket(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Per-verb contentId builders

    static func kilterSession(id: String) -> String {
        KilterClimbIdentity.uuidV5(namespace: nsSession, name: "kilterSession|\(canon(id))")
    }

    static func workoutSession(id: String) -> String {
        KilterClimbIdentity.uuidV5(namespace: nsSession, name: "workoutSession|\(canon(id))")
    }

    /// Per-send identity — SHARED FIELDS ONLY: `(climbUUID, difficulty, statusRaw, dayBucket, sessionId?)`.
    /// NEVER the row id (Android `KilterLogEntry` autogenerates a Long), or dedup breaks across devices.
    static func kilterSend(climbUUID: String, difficulty: Double, statusRaw: String,
                           date: Date, sessionId: String?) -> String {
        let name = "send|\(canon(climbUUID))|\(fixed(difficulty))|\(canon(statusRaw))|\(dayBucket(date))|\(sessionId.map(canon) ?? "none")"
        return KilterClimbIdentity.uuidV5(namespace: nsFeedItem, name: name)
    }

    static func climb(uuid: String) -> String {
        KilterClimbIdentity.uuidV5(namespace: nsClimb, name: canon(uuid))
    }

    static func clip(localIdentifier: String) -> String {
        KilterClimbIdentity.uuidV5(namespace: nsClip, name: canon(localIdentifier))
    }
}
