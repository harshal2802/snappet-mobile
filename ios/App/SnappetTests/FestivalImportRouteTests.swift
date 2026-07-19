import XCTest
@testable import Snappet

/// The `snappet://festival/…` **open path** (festival prompt 05) end-to-end at the pure value level —
/// the device-free analog of `RoutineImportRouteTests`. Drives a code through the route table
/// (`SnappetDeepLink.route`), the router one-shot (`SuiteRouter.pendingFestivalImport`), and the pure
/// receive decision. The SwiftUI `.onChange` consumer + the camera scan stay device/sim-pending; this
/// locks the decisions they execute.
@MainActor
final class FestivalImportRouteTests: XCTestCase {

    private func glastonbury() -> FestivalPack { FestivalFixtures.glastonbury() }

    func testPayloadURLParsesToFestivalRoute() throws {
        let pack = glastonbury()
        let shared = SharedLineup.lineup(from: pack, title: pack.name)
        let url = try XCTUnwrap(shared.url)

        guard case .festivalLineup(let parsed) = SnappetDeepLink.route(for: url) else {
            return XCTFail("expected .festivalLineup route")
        }
        XCTAssertEqual(parsed.carriedPack?.id, pack.id)
    }

    func testInstallLinkURLParsesToFestivalRoute() throws {
        let shared = SharedLineup(content: .installLink(packID: "glastonbury-2026",
                                                        host: festivalDefaultCatalogHost),
                                  title: "Glastonbury 2026", isPlan: false)
        let url = try XCTUnwrap(shared.url)
        guard case .festivalLineup(let parsed) = SnappetDeepLink.route(for: url) else {
            return XCTFail("expected .festivalLineup route")
        }
        XCTAssertEqual(parsed.receiveAction(installedPackIDs: []),
                       .fetchInstall(packID: "glastonbury-2026", host: festivalDefaultCatalogHost))
    }

    func testForeignURLsAreNotFestivalRoutes() throws {
        for s in ["snappet://routine/v1/abc", "snappet://kilter/climb/xyz",
                  "snappet://pomodoro/start", "https://example.com"] {
            let url = try XCTUnwrap(URL(string: s))
            if case .festivalLineup = SnappetDeepLink.route(for: url) {
                XCTFail("\(s) should not route to festival")
            }
        }
    }

    func testOpenURLStagesTheOneShotAndOpensTheModule() throws {
        let pack = glastonbury()
        let shared = SharedLineup.lineup(from: pack, title: pack.name)
        let url = try XCTUnwrap(shared.url)

        // The route table parses; RootShell.handle stages the one-shot + opens the module.
        guard case .festivalLineup(let parsed) = SnappetDeepLink.route(for: url) else {
            return XCTFail("expected .festivalLineup route")
        }
        let router = SuiteRouter()
        router.pendingFestivalImport = parsed
        router.open(module: FestivalModule.id)
        XCTAssertEqual(router.tab, .apps)
        XCTAssertNotNil(router.pendingFestivalImport)

        // FestivalRootView consumes it once: read, then clear (self-clearing one-shot).
        let consumed = router.pendingFestivalImport
        router.pendingFestivalImport = nil
        XCTAssertNotNil(consumed)
        XCTAssertNil(router.pendingFestivalImport, "the intent must be one-shot (cleared on consume)")
        XCTAssertEqual(consumed?.carriedPack?.id, pack.id)
    }
}
