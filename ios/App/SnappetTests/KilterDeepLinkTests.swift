import XCTest
@testable import Snappet

/// Unit tests for the **pure** climb-share codec `KilterClimbLink`. This is the off-device-testable
/// half of QR sharing: the URL round-trips a `climb_uuid` (+ optional angle) so a scanned code opens
/// the same climb on another phone, offline. The camera path stays device-pending.
final class KilterDeepLinkTests: XCTestCase {
    func testRoundTripWithAngle() {
        let link = KilterClimbLink(uuid: "abc123", angle: 40)
        XCTAssertEqual(link.encoded, "snappet://kilter/climb/abc123?angle=40")
        let parsed = KilterClimbLink(decoding: link.encoded)
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(parsed?.angle, 40)
    }

    func testRoundTripWithoutAngle() {
        let link = KilterClimbLink(uuid: "deadbeef")
        XCTAssertEqual(link.encoded, "snappet://kilter/climb/deadbeef")
        let parsed = KilterClimbLink(decoding: link.encoded)
        XCTAssertEqual(parsed?.uuid, "deadbeef")
        XCTAssertNil(parsed?.angle)
    }

    func testTrimsWhitespaceAndIsSchemeCaseInsensitive() {
        let parsed = KilterClimbLink(decoding: "  SNAPPET://kilter/climb/xyz?angle=25  ")
        XCTAssertEqual(parsed?.uuid, "xyz")
        XCTAssertEqual(parsed?.angle, 25)
    }

    func testRejectsForeignAndMalformedCodes() {
        for bad in [
            "https://kilterboardapp.com/climbs/abc",   // a web link, not ours
            "snappet://workout/session/1",             // our scheme, wrong module
            "snappet://kilter/climb/",                 // missing uuid
            "snappet://kilter/history",                // not a climb
            "abc123",                                  // bare text
            "",
        ] {
            XCTAssertNil(KilterClimbLink(decoding: bad), "should reject \(bad)")
        }
    }
}
