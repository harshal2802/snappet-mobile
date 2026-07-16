import XCTest
@testable import Snappet

/// Unit tests for the **pure** `.fpack` wire codec (festival prompt 01): magic + version byte +
/// raw-DEFLATE JSON round-trips a whole lineup; tampered / oversized / unversioned blobs are rejected
/// with typed errors; and set ids are UUIDv5 content identity — identical across decodes, re-downloads,
/// and cosmetic pack edits. No simulator needed.
final class FestivalPackTests: XCTestCase {

    // MARK: - Round-trip

    func testRoundTripPreservesTheWholeLineup() throws {
        let pack = FestivalFixtures.glastonbury()
        let data = try pack.fpackData()
        let decoded = try FestivalPack.decode(fpack: data)

        XCTAssertEqual(decoded, pack, "codec must be lossless (ids re-stamped deterministically)")
        XCTAssertEqual(decoded.name, "Glastonbury 2026")
        XCTAssertEqual(decoded.days.count, 2)
        XCTAssertEqual(decoded.days[0].stages.map(\.name),
                       ["Pyramid Stage", "West Holts", "Arcadia"])
        XCTAssertEqual(decoded.days[0].stages[0].sets.map(\.artist),
                       ["Little Simz", "Fred again.."])
        // Absolute instants survive exactly (whole-second fixture dates).
        XCTAssertEqual(FestivalFixtures.set(named: "Fred again..", in: decoded).start,
                       FestivalFixtures.date("2026-06-27T22:15"))
    }

    func testPackIsSmallEnoughToHost() throws {
        // README: "packs are tiny (a lineup is text)" — the fixture should deflate to well under 10 KB.
        let data = try FestivalFixtures.glastonbury().fpackData()
        XCTAssertLessThan(data.count, 10_000)
    }

    func testDatesEncodeWithTheFestivalsUTCOffset() throws {
        let data = try FestivalFixtures.glastonbury().fpackData()
        let json = try XCTUnwrap(ZlibCodec.inflate(data.dropFirst(5)))
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        // A pack built in Britain reads like the poster: 22:15 local, +01:00 in the string.
        XCTAssertTrue(text.contains("2026-06-27T22:15:00+01:00"),
                      "set times must carry the festival's offset, not Z/UTC")
    }

    func testNegativeOffsetEncodesAndParsesItsOwnZone() {
        // A Coachella-shaped pack (PDT, −07:00) writes and reads its own zone symmetrically.
        let instant = FestivalFixtures.date("2026-04-10T20:00", offsetSeconds: -7 * 3600)
        let iso = FestivalPack.isoString(instant, utcOffsetSeconds: -7 * 3600)
        XCTAssertEqual(iso, "2026-04-10T20:00:00-07:00")
        XCTAssertEqual(FestivalPack.parseISO(iso), instant)
    }

    // MARK: - Content identity (UUIDv5)

    func testSetIDsAreIdenticalAcrossTwoDecodes() throws {
        let data = try FestivalFixtures.glastonbury().fpackData()
        let a = try FestivalPack.decode(fpack: data)
        let b = try FestivalPack.decode(fpack: data)
        XCTAssertEqual(a.allSets.map(\.id), b.allSets.map(\.id))
        XCTAssertEqual(Set(a.allSets.map(\.id)).count, a.allSets.count, "ids are unique per set")
    }

    func testSetIDsSurviveAReEncodeAndAFriendsCopy() throws {
        // Re-download / friend-share = decode → encode → decode. Ids must converge.
        let original = FestivalFixtures.glastonbury()
        let copy = try FestivalPack.decode(fpack: try FestivalPack.decode(
            fpack: original.fpackData()).fpackData())
        XCTAssertEqual(copy.allSets.map(\.id), original.allSets.map(\.id))
    }

    func testContentIDNormalizesCaseAndWhitespace() {
        let a = FestivalSet.contentID(
            festivalID: "glastonbury-2026", stage: "West Holts",
            set: FestivalFixtures.set("Fred again..", "2026-06-27T22:15", "2026-06-27T23:45"))
        let b = FestivalSet.contentID(
            festivalID: "Glastonbury-2026", stage: "  west   holts ",
            set: FestivalFixtures.set(" FRED  AGAIN.. ", "2026-06-27T22:15", "2026-06-27T23:45"))
        XCTAssertEqual(a, b, "cosmetic pack edits must not re-key a set")
    }

    func testContentIDChangesWhenTheContentDoes() {
        let base = FestivalFixtures.set("Overmono", "2026-06-27T23:30", "2026-06-28T01:00")
        let shifted = FestivalFixtures.set("Overmono", "2026-06-27T23:45", "2026-06-28T01:00")
        XCTAssertNotEqual(
            FestivalSet.contentID(festivalID: "g", stage: "West Holts", set: base),
            FestivalSet.contentID(festivalID: "g", stage: "West Holts", set: shifted))
        XCTAssertNotEqual(
            FestivalSet.contentID(festivalID: "g", stage: "West Holts", set: base),
            FestivalSet.contentID(festivalID: "g", stage: "Arcadia", set: base),
            "same artist + times on another stage is a different set")
    }

    func testStampedStageLabelMakesSetsSelfContained() {
        let pack = FestivalFixtures.glastonbury()
        XCTAssertEqual(FestivalFixtures.set(named: "Overmono", in: pack).stage, "West Holts")
        XCTAssertEqual(FestivalFixtures.set(named: "Eric Prydz", in: pack).stage, "Arcadia")
    }

    // MARK: - Rejection (typed errors the install UI shows verbatim)

    func testRejectsForeignData() {
        XCTAssertThrowsError(try FestivalPack.decode(fpack: Data("not a pack at all".utf8))) {
            XCTAssertEqual($0 as? FestivalPack.FPackError, .notAPack)
        }
        XCTAssertThrowsError(try FestivalPack.decode(fpack: Data())) {
            XCTAssertEqual($0 as? FestivalPack.FPackError, .notAPack)
        }
        XCTAssertThrowsError(try FestivalPack.decode(fpack: Data("FPAK".utf8))) {
            XCTAssertEqual($0 as? FestivalPack.FPackError, .notAPack, "header alone is not a pack")
        }
    }

    func testRejectsUnsupportedFutureVersion() throws {
        var data = try FestivalFixtures.glastonbury().fpackData()
        data[data.startIndex + 4] = 9   // stamp a future wire version into the header byte
        XCTAssertThrowsError(try FestivalPack.decode(fpack: data)) {
            XCTAssertEqual($0 as? FestivalPack.FPackError, .unsupportedVersion(9))
        }
    }

    func testRejectsTamperedBody() throws {
        var data = try FestivalFixtures.glastonbury().fpackData()
        // Corrupt the deflate stream mid-body.
        let mid = data.startIndex + data.count / 2
        data[mid] ^= 0xFF
        data[mid + 1] ^= 0xFF
        XCTAssertThrowsError(try FestivalPack.decode(fpack: data)) { error in
            let e = error as? FestivalPack.FPackError
            XCTAssertTrue(e == .corrupted || e == .undecodable, "got \(String(describing: e))")
        }
    }

    func testRejectsTruncatedBody() throws {
        let data = try FestivalFixtures.glastonbury().fpackData()
        let truncated = data.prefix(data.count / 2)
        XCTAssertThrowsError(try FestivalPack.decode(fpack: Data(truncated)))
    }

    func testRejectsOversizedFileBeforeInflating() {
        var huge = Data("FPAK".utf8)
        huge.append(1)
        huge.append(Data(count: FestivalPack.maxPackBytes))
        XCTAssertThrowsError(try FestivalPack.decode(fpack: huge)) {
            XCTAssertEqual($0 as? FestivalPack.FPackError, .tooLarge(huge.count))
        }
    }

    // MARK: - Day windows (the explicit 06:00 day-boundary model)

    func testDayWindowRunsRolloverToRollover() throws {
        let pack = FestivalFixtures.glastonbury()
        let window = try XCTUnwrap(pack.days[0].window(utcOffsetSeconds: pack.utcOffsetSeconds))
        XCTAssertEqual(window.start, FestivalFixtures.date("2026-06-27T06:00"))
        XCTAssertEqual(window.end, FestivalFixtures.date("2026-06-28T06:00"))
    }

    func testAOneAMClipBelongsToThePreviousPosterDay() {
        let pack = FestivalFixtures.glastonbury()
        // 01:30 on the calendar-Sunday night is still poster-Saturday.
        let day = pack.day(containing: FestivalFixtures.date("2026-06-28T01:30"))
        XCTAssertEqual(day?.date, "2026-06-27")
        // …and 07:00 Sunday morning is Sunday.
        XCTAssertEqual(pack.day(containing: FestivalFixtures.date("2026-06-28T07:00"))?.date,
                       "2026-06-28")
        XCTAssertNil(pack.day(containing: FestivalFixtures.date("2026-07-05T20:00")))
    }
}
