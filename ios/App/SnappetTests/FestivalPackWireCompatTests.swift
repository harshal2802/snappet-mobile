import XCTest
@testable import Snappet

/// Cross-language wire compatibility: the fixture below is the **actual published bytes** of
/// `glastonbury-2026.fpack` as built by the web repo's `scripts/build-fpack.py` (the Snappet Pages
/// `music-festivals/` pack builder). If either side drifts — the builder stops emitting
/// `"FPAK" + version + raw-DEFLATE JSON`, or the app's codec/Codable changes shape — this test
/// fails before a user's download does. Regenerate the fixture from the web repo:
/// `python3 scripts/build-fpack.py && base64 -i src/frontend/public/music-festivals/glastonbury-2026.fpack`.
final class FestivalPackWireCompatTests: XCTestCase {

    /// `glastonbury-2026.fpack`, byte-for-byte as hosted (built 2026-07-16, 1 607 bytes).
    private let publishedBase64 = ""
        + "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"
        + "3fvwoDH55e0txPia5eCCINLpQRR9/Rc="

    func testPublishedPackDecodesValidatesAndCarriesTheExpectedLineup() throws {
        let data = try XCTUnwrap(Data(base64Encoded: publishedBase64),
                                 "the fixture must be valid base64")
        XCTAssertEqual(data.count, 1607, "byte-for-byte the published file")

        // Decode through the ONE production entry point the installer uses.
        let pack = try FestivalPack.decode(fpack: data)
        let validated = try FestivalPackValidator.validate(pack)

        XCTAssertEqual(pack.id, "glastonbury-2026")
        XCTAssertEqual(pack.name, "Glastonbury 2026")
        XCTAssertEqual(pack.location, "Worthy Farm, Pilton")
        XCTAssertEqual(pack.utcOffsetSeconds, 3600)   // BST
        XCTAssertEqual(pack.days.map(\.date), ["2026-06-26", "2026-06-27", "2026-06-28"])
        // Exactly what the hosted manifest.json advertises for this pack.
        XCTAssertEqual(validated.dayCount, 3)
        XCTAssertEqual(validated.stageCount, 18)
        XCTAssertEqual(validated.setCount, 84)

        // A known set decodes to the right absolute instants + stamped content identity.
        let fred = try XCTUnwrap(pack.allSets.first { $0.artist == "Fred again.." })
        XCTAssertEqual(fred.stage, "Pyramid Stage")
        XCTAssertEqual(fred.start, FestivalFixtures.date("2026-06-27T22:15"))
        XCTAssertEqual(fred.end, FestivalFixtures.date("2026-06-27T23:45"))
        XCTAssertEqual(fred.id,
                       FestivalSet.contentID(festivalID: pack.id, stage: fred.stage, set: fred),
                       "set ids are the UUIDv5 content identity, stamped on decode")

        // Late-night sets built from the source's `HH:MM < 06:00` shorthand landed on the next
        // calendar date but the SAME poster day (the 06:00 rollover both sides share).
        let mallGrab = try XCTUnwrap(pack.allSets.first { $0.artist == "Mall Grab" })
        XCTAssertEqual(mallGrab.start, FestivalFixtures.date("2026-06-28T00:30"))
        XCTAssertEqual(pack.day(containing: mallGrab.start)?.date, "2026-06-27")
    }
}
