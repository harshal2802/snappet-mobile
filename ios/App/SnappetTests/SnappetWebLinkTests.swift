import XCTest
@testable import Snappet

/// Universal links (prompt 200): every `snappet://` link has an https twin that routes the same.
final class SnappetWebLinkTests: XCTestCase {
    private let base = "https://harshal2802.github.io/Snappet/open"

    func testTheTwoFormsMapBothWays() {
        let app = "snappet://kilter/climb/abc-123?angle=40"
        let web = "\(base)/kilter/climb/abc-123?angle=40"
        XCTAssertEqual(SnappetWebLink.webForm(app), web)
        XCTAssertEqual(SnappetWebLink.appForm(web), app)
        XCTAssertEqual(SnappetWebLink.appForm(SnappetWebLink.webForm("snappet://finish")), "snappet://finish")
        // Percent-encoding survives the trip.
        let log = "snappet://log?activity=Bench%20Press&reps=5"
        XCTAssertEqual(SnappetWebLink.appForm(SnappetWebLink.webForm(log)), log)
    }

    func testOthersPassThrough() {
        XCTAssertEqual(SnappetWebLink.appForm("https://example.com/Snappet/open/finish"), "https://example.com/Snappet/open/finish")
        XCTAssertEqual(SnappetWebLink.appForm("https://harshal2802.github.io/Snappet/workout"),
                       "https://harshal2802.github.io/Snappet/workout", "only /open/ is the app's")
        XCTAssertEqual(SnappetWebLink.appForm("\(base)/"), "\(base)/", "nothing after /open/")
        XCTAssertEqual(SnappetWebLink.webForm("https://example.com/x"), "https://example.com/x")
        XCTAssertEqual(SnappetWebLink.appForm("  snappet://finish \n"), "snappet://finish")
    }

    func testTheHttpsFormRoutesLikeTheAppForm() {
        let climb = KilterClimbLink(uuid: "11111111-1111-4111-8111-111111111111", angle: 40)
        let web = SnappetWebLink.webForm(climb.encoded)
        XCTAssertTrue(web.hasPrefix(base))
        XCTAssertEqual(KilterClimbLink(decoding: web), climb, "the in-app scanner reads the https QR")
        XCTAssertEqual(SnappetDeepLink.route(for: URL(string: web)!), .kilterClimb(climb))
        XCTAssertEqual(SnappetDeepLink.route(for: URL(string: "\(base)/finish")!), .workout(.finish))
        XCTAssertEqual(SnappetDeepLink.route(for: URL(string: "\(base)/pomodoro/start")!), .startFocus)
    }

    func testSharedPayloadsDecodeFromTheHttpsForm() throws {
        let routine = SharedRoutine(name: "Push", detail: nil, exercises: [])
        let web = SnappetWebLink.webForm(routine.encoded)
        XCTAssertEqual(SharedRoutine(decoding: web)?.name, "Push")
        XCTAssertEqual(routine.encodedByteCount, web.utf8.count, "the QR size check counts what the QR carries")

        let invite = HouseholdInvite.make(householdID: UUID(), name: "Home")
        XCTAssertEqual(HouseholdInvite(url: SnappetWebLink.webForm(invite.url))?.token, invite.token)
    }
}
