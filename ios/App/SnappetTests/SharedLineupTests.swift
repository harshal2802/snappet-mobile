import XCTest
@testable import Snappet

/// The festival QR-sharing codec + payload-vs-link cliff (festival prompt 05), the device-free analog
/// of `SharedRoutineTests`. Round-trips a plan / lineup through the deflate blob, proves the carried
/// set ids equal the source pack's (so a shared plan stars the right sets), exercises tampered /
/// oversized / wrong-version rejection, and pins the size boundary where a payload falls back to an
/// install link. The camera scan + the SwiftUI share sheet stay device-pending.
final class SharedLineupTests: XCTestCase {

    private func glastonbury() -> FestivalPack { FestivalFixtures.glastonbury() }

    // MARK: - Payload round-trip

    func testWholeLineupPayloadRoundTrips() throws {
        let pack = glastonbury()
        let shared = SharedLineup.lineup(from: pack, title: "Glastonbury 2026")
        let url = try XCTUnwrap(shared.url)

        let decoded = try XCTUnwrap(SharedLineup(decoding: url.absoluteString))
        XCTAssertFalse(decoded.isPlan)
        XCTAssertEqual(decoded.title, "Glastonbury 2026")
        let decodedPack = try XCTUnwrap(decoded.carriedPack)
        // Same festival meta + every set id (UUIDv5 content identity survives the blob).
        XCTAssertEqual(decodedPack.id, pack.id)
        XCTAssertEqual(Set(decodedPack.allSets.map(\.id)), Set(pack.allSets.map(\.id)))
        XCTAssertEqual(decodedPack.allSets.count, pack.allSets.count)
    }

    func testPlanSubsetCarriesOnlyStarredSetsWithMatchingIds() throws {
        let pack = glastonbury()
        let starred: Set<UUID> = [
            FestivalFixtures.set(named: "Fred again..", in: pack).id,
            FestivalFixtures.set(named: "Four Tet", in: pack).id,
        ]
        let shared = SharedLineup.plan(from: pack, starredSetIDs: starred, title: "My plan")
        let decoded = try XCTUnwrap(SharedLineup(decoding: try XCTUnwrap(shared.url).absoluteString))

        XCTAssertTrue(decoded.isPlan)
        let decodedPack = try XCTUnwrap(decoded.carriedPack)
        // Exactly the two starred sets, and their ids equal the ids in the FULL pack — so applying the
        // plan on the receiver stars the very sets the sharer starred.
        XCTAssertEqual(Set(decodedPack.allSets.map(\.id)), starred)
        // Empty stages/days were dropped.
        XCTAssertTrue(decodedPack.allSets.allSatisfy { starred.contains($0.id) })
    }

    func testSubsetPackStaysValid() throws {
        // A plan is a real pack — it must still pass the installer's validator on the receiver.
        let pack = glastonbury()
        let starred: Set<UUID> = [FestivalFixtures.set(named: "Olivia Dean", in: pack).id]
        let subset = SharedLineup.subsetPack(pack, starredSetIDs: starred)
        XCTAssertNoThrow(try FestivalPackValidator.validate(subset))
    }

    func testCompressionActuallyShrinksTheBlob() throws {
        let pack = glastonbury()
        let shared = SharedLineup.lineup(from: pack, title: "Glastonbury 2026")
        let rawJSON = try JSONEncoder().encode(pack)
        // The deflated + base64url URL should be smaller than the raw pack JSON.
        XCTAssertLessThan(shared.encodedByteCount, rawJSON.count)
    }

    // MARK: - The payload-vs-link cliff

    func testSmallPlanStaysAScannablePayload() throws {
        let pack = glastonbury()
        let starred = Set(pack.allSets.prefix(4).map(\.id))
        let shared = SharedLineup.plan(from: pack, starredSetIDs: starred, title: "My plan")
        XCTAssertTrue(shared.fitsInScannableQR, "a handful of sets belongs IN the code")
        // scannableForm keeps it a payload.
        if case .payload = shared.scannableForm().content {} else {
            XCTFail("a small plan should stay a payload QR")
        }
    }

    func testHugeLineupFallsBackToInstallLink() throws {
        // A many-set festival exceeds the scannable cap → scannableForm hands back an install link.
        let pack = FestivalFixtures.bigFestival(days: 3, stagesPerDay: 8, setsPerStage: 18)
        let shared = SharedLineup.lineup(from: pack, title: pack.name)
        XCTAssertFalse(shared.fitsInScannableQR, "a whole festival is too dense for a payload QR")

        let fallback = shared.scannableForm(host: festivalDefaultCatalogHost)
        guard case .installLink(let packID, let host) = fallback.content else {
            return XCTFail("expected an install-link fallback")
        }
        XCTAssertEqual(packID, pack.id)
        XCTAssertEqual(host, festivalDefaultCatalogHost)
        XCTAssertTrue(fallback.fitsInScannableQR, "an install link is always tiny")
    }

    func testInstallLinkRoundTripsCarryingHostTitleAndKind() throws {
        let shared = SharedLineup(content: .installLink(packID: "glastonbury-2026",
                                                        host: "https://example.test/music-festivals/"),
                                  title: "Glastonbury 2026", isPlan: false)
        let decoded = try XCTUnwrap(SharedLineup(decoding: try XCTUnwrap(shared.url).absoluteString))
        guard case .installLink(let packID, let host) = decoded.content else {
            return XCTFail("expected install link")
        }
        XCTAssertEqual(packID, "glastonbury-2026")
        XCTAssertEqual(host, "https://example.test/music-festivals/")
        XCTAssertEqual(decoded.title, "Glastonbury 2026")
        XCTAssertFalse(decoded.isPlan)
    }

    func testInstallLinkDefaultsHostWhenAbsent() throws {
        let decoded = try XCTUnwrap(SharedLineup(decoding: "snappet://festival/install/glastonbury-2026"))
        guard case .installLink(_, let host) = decoded.content else {
            return XCTFail("expected install link")
        }
        XCTAssertEqual(host, festivalDefaultCatalogHost)
    }

    // MARK: - Rejection

    func testRejectsForeignAndMalformedCodes() {
        XCTAssertNil(SharedLineup(decoding: "https://example.com"))
        XCTAssertNil(SharedLineup(decoding: "snappet://routine/v1/abc"))     // a routine, not a lineup
        XCTAssertNil(SharedLineup(decoding: "snappet://kilter/climb/xyz"))
        XCTAssertNil(SharedLineup(decoding: "snappet://festival/v1/"))       // empty blob
        XCTAssertNil(SharedLineup(decoding: "snappet://festival/v1/!!!not-base64!!!"))
        XCTAssertNil(SharedLineup(decoding: "not a url at all"))
    }

    func testRejectsWrongVersionSegment() throws {
        let pack = glastonbury()
        let shared = SharedLineup.lineup(from: pack, title: "Glastonbury 2026")
        let good = try XCTUnwrap(shared.url).absoluteString
        // Bump the version segment the parser checks against — a future /v2/ code is rejected cleanly.
        let bumped = good.replacingOccurrences(of: "/v\(SharedLineup.version)/", with: "/v99/")
        XCTAssertNotEqual(bumped, good)
        XCTAssertNil(SharedLineup(decoding: bumped))
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        let pack = glastonbury()
        let url = try XCTUnwrap(SharedLineup.lineup(from: pack, title: "G").url).absoluteString
        let upper = url.replacingOccurrences(of: "snappet://festival/",
                                             with: "SNAPPET://FESTIVAL/")
        XCTAssertNotNil(SharedLineup(decoding: upper))
    }

    // MARK: - Receive decision (pure)

    func testReceiveActionForWholeLineupInstalls() {
        let pack = glastonbury()
        let shared = SharedLineup.lineup(from: pack, title: pack.name)
        XCTAssertEqual(shared.receiveAction(installedPackIDs: []),
                       .installLineup(packID: pack.id))
    }

    func testReceiveActionForPlanAppliesWhenLineupInstalled() {
        let pack = glastonbury()
        let starred = Set(pack.allSets.prefix(3).map(\.id))
        let shared = SharedLineup.plan(from: pack, starredSetIDs: starred, title: "My plan")
        let action = shared.receiveAction(installedPackIDs: [pack.id])
        guard case .applyPlan(let packID, let setIDs) = action else {
            return XCTFail("expected applyPlan")
        }
        XCTAssertEqual(packID, pack.id)
        XCTAssertEqual(Set(setIDs), starred)
    }

    func testReceiveActionForPlanInstallsSubsetWhenLineupMissing() {
        let pack = glastonbury()
        let starred = Set(pack.allSets.prefix(2).map(\.id))
        let shared = SharedLineup.plan(from: pack, starredSetIDs: starred, title: "My plan")
        XCTAssertEqual(shared.receiveAction(installedPackIDs: []),
                       .installPlan(packID: pack.id))
    }

    func testReceiveActionForInstallLinkFetches() {
        let shared = SharedLineup(content: .installLink(packID: "glastonbury-2026",
                                                        host: festivalDefaultCatalogHost),
                                  title: "Glastonbury 2026", isPlan: false)
        XCTAssertEqual(shared.receiveAction(installedPackIDs: []),
                       .fetchInstall(packID: "glastonbury-2026", host: festivalDefaultCatalogHost))
    }
}
