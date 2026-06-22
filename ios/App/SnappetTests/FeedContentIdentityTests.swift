import XCTest
@testable import Snappet

/// Golden-vector tests for the pure UUIDv5 feed content identity (F0b). The expected UUIDs are
/// cross-computed (SHA-1 over namespace-bytes ‖ canonical name) so the Kotlin FA0b port must match.
final class FeedContentIdentityTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testGoldenVectors() {
        XCTAssertEqual(FeedContentIdentity.kilterSession(id: "00000000-0000-0000-0000-000000000001"),
                       "534e189c-4952-549b-9589-5fe932ab3417")
        XCTAssertEqual(FeedContentIdentity.workoutSession(id: "11111111-1111-1111-1111-111111111111"),
                       "5b9636dd-e00f-5c71-b9e6-9d65ae22ab64")
        XCTAssertEqual(FeedContentIdentity.kilterSend(climbUUID: "abc123", difficulty: 19, statusRaw: "sent",
                                                      date: date(2026, 6, 20), sessionId: "S1"),
                       "8ac9abf7-ce59-5d86-9fc6-ee87bcbe8ac0")
        XCTAssertEqual(FeedContentIdentity.climb(uuid: "abc123"),
                       "bfcde948-e39a-5862-8986-6baeda2061ec")
    }

    /// The per-send identity uses SHARED FIELDS ONLY (never the Android-unstable row id):
    /// same send facts at different times of the SAME day collapse to one id.
    func testPerSendUsesSharedFieldsNotRowId() {
        let a = FeedContentIdentity.kilterSend(climbUUID: "X", difficulty: 16, statusRaw: "flash", date: date(2026, 6, 20, 9), sessionId: "S")
        let b = FeedContentIdentity.kilterSend(climbUUID: "X", difficulty: 16, statusRaw: "flash", date: date(2026, 6, 20, 21), sessionId: "S")
        XCTAssertEqual(a, b, "same-day same-facts sends must dedup (dayBucket), regardless of when/which row")

        XCTAssertNotEqual(a, FeedContentIdentity.kilterSend(climbUUID: "X", difficulty: 16, statusRaw: "flash", date: date(2026, 6, 21, 9), sessionId: "S"), "different day")
        XCTAssertNotEqual(a, FeedContentIdentity.kilterSend(climbUUID: "X", difficulty: 16, statusRaw: "sent",  date: date(2026, 6, 20, 9), sessionId: "S"), "different status")
        XCTAssertNotEqual(a, FeedContentIdentity.kilterSend(climbUUID: "Y", difficulty: 16, statusRaw: "flash", date: date(2026, 6, 20, 9), sessionId: "S"), "different climb")
    }

    func testDeterministicAndRFC4122() {
        let id = FeedContentIdentity.climb(uuid: "anything")
        XCTAssertEqual(id, FeedContentIdentity.climb(uuid: "anything"))
        let chars = Array(id)
        XCTAssertEqual(chars[14], "5", "version 5 nibble")
        XCTAssertTrue("89ab".contains(chars[19]), "RFC 4122 variant nibble")
    }

    func testCanonicalizationTrimsWhitespace() {
        XCTAssertEqual(FeedContentIdentity.climb(uuid: "  abc123 "), FeedContentIdentity.climb(uuid: "abc123"))
    }
}
