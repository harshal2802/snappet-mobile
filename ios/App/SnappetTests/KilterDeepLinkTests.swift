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

/// The `onOpenURL` half of #75 — the registered `snappet://` scheme's pure route table
/// (`SnappetDeepLink`) and the climb-landing decision (`KilterDeepLinkRouting`) the URL path and
/// the in-app scanner both route through. The simulator/Camera halves stay device/sim-pending
/// (`xcrun simctl openurl` drives them); these lock the decisions they execute.
final class SnappetDeepLinkRouteTests: XCTestCase {

    // MARK: - URL → route

    func testClimbURLRoutesToKilter() throws {
        let url = try XCTUnwrap(URL(string: "snappet://kilter/climb/abc123?angle=40"))
        XCTAssertEqual(SnappetDeepLink.route(for: url),
                       .kilterClimb(KilterClimbLink(uuid: "abc123", angle: 40)))
    }

    func testClimbURLWithoutAngleRoutes() throws {
        let url = try XCTUnwrap(URL(string: "snappet://kilter/climb/deadbeef"))
        XCTAssertEqual(SnappetDeepLink.route(for: url),
                       .kilterClimb(KilterClimbLink(uuid: "deadbeef")))
    }

    func testPomodoroStartRoutesToFocus() throws {
        let url = try XCTUnwrap(URL(string: "snappet://pomodoro/start"))
        XCTAssertEqual(SnappetDeepLink.route(for: url), .startFocus)
    }

    func testPomodoroStartIsSchemeAndHostCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "SNAPPET://Pomodoro/start"))
        XCTAssertEqual(SnappetDeepLink.route(for: url), .startFocus)
    }

    func testForeignURLsDoNotRoute() throws {
        for bad in [
            "https://kilterboardapp.com/climbs/abc",   // not our scheme
            "snappet://workout/session/1",             // our scheme, no route (yet)
            "snappet://kilter/history",                // kilter, not a climb
            "snappet://pomodoro",                      // pomodoro, but not /start
            "snappet://pomodoro/history",              // pomodoro, wrong path
            "snappet://pomodoro/start/extra",          // pomodoro/start with trailing junk
            "snappet://routine/v1/",                   // routine, missing blob
            "snappet://routine/v9/abc",                // routine, unknown version
        ] {
            let url = try XCTUnwrap(URL(string: bad))
            XCTAssertNil(SnappetDeepLink.route(for: url), "should not route \(bad)")
        }
    }

    // MARK: - Routine share route (workout-redesign E6) — additive, doesn't regress climb scanning

    func testRoutineURLRoutesToRoutineImport() throws {
        let shared = SharedRoutine(name: "Leg Day", detail: nil,
                                   exercises: [RoutineExercise(exerciseId: "barbell_squat", sets: 5,
                                                               reps: "5", restSeconds: 120)])
        let url = try XCTUnwrap(shared.url)
        guard case .routine(let decoded) = SnappetDeepLink.route(for: url) else {
            return XCTFail("expected .routine route")
        }
        XCTAssertEqual(decoded.name, "Leg Day")
        XCTAssertEqual(decoded.exercises.count, 1)
    }

    func testClimbStillRoutesToKilterNotRoutine() throws {
        // The additive routine decode must be tried in a way that DOESN'T swallow a climb link.
        let url = try XCTUnwrap(URL(string: "snappet://kilter/climb/abc123?angle=40"))
        XCTAssertEqual(SnappetDeepLink.route(for: url),
                       .kilterClimb(KilterClimbLink(uuid: "abc123", angle: 40)))
    }

    // MARK: - Climb link → landing

    func testInstalledClimbOpensAndAdoptsAnOfferedAngle() {
        let d = KilterDeepLinkRouting.destination(
            for: KilterClimbLink(uuid: "abc", angle: 40),
            climbInstalled: true, availableAngles: [20, 40, 70])
        XCTAssertEqual(d, .openClimb(uuid: "abc", adoptAngle: 40))
    }

    func testInstalledClimbKeepsUserAngleWhenSharersIsNotOffered() {
        // The sharer climbed at 42° but this board only offers the standard angles — don't
        // force an angle the local picker can't represent (the scanner's longstanding rule).
        let d = KilterDeepLinkRouting.destination(
            for: KilterClimbLink(uuid: "abc", angle: 42),
            climbInstalled: true, availableAngles: [20, 40, 70])
        XCTAssertEqual(d, .openClimb(uuid: "abc", adoptAngle: nil))
    }

    func testInstalledClimbWithNoSharedAngleAdoptsNothing() {
        let d = KilterDeepLinkRouting.destination(
            for: KilterClimbLink(uuid: "abc"),
            climbInstalled: true, availableAngles: [20, 40, 70])
        XCTAssertEqual(d, .openClimb(uuid: "abc", adoptAngle: nil))
    }

    func testMissingClimbLandsGracefully() {
        let d = KilterDeepLinkRouting.destination(
            for: KilterClimbLink(uuid: "not-here", angle: 40),
            climbInstalled: false, availableAngles: [20, 40, 70])
        XCTAssertEqual(d, .explainMissing(uuid: "not-here"))
    }

    func testNoCatalogAtAllIsJustTheMissingCase() {
        // Fresh install, catalog gate showing: same graceful landing, empty angle list.
        let d = KilterDeepLinkRouting.destination(
            for: KilterClimbLink(uuid: "abc", angle: 40),
            climbInstalled: false, availableAngles: [])
        XCTAssertEqual(d, .explainMissing(uuid: "abc"))
    }
}
