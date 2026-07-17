import XCTest
import SwiftData
@testable import Snappet

/// The install funnel (festival prompt 02): provider bytes → `FestivalPack.decode` →
/// `FestivalPackValidator` → one `FestivalLineup` row. Runs against an in-memory
/// `ModelContainer` with stub providers — no network, no UI.
@MainActor
final class FestivalInstallerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private struct StubProvider: FestivalPackProvider {
        let data: Data
        var sourceLabel: String { "Test stub" }
        func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            progress(1)
            return data
        }
    }

    private func lineups() -> [FestivalLineup] {
        (try? context.fetch(FetchDescriptor<FestivalLineup>())) ?? []
    }

    // MARK: - Happy path

    func testInstallDecodesValidatesAndPersistsOneRow() async throws {
        let pack = FestivalFixtures.glastonbury()
        let installer = FestivalLineupInstaller()

        let lineup = await installer.install(using: StubProvider(data: try pack.fpackData()),
                                             into: context)

        XCTAssertNotNil(lineup)
        XCTAssertEqual(installer.phase, .installed(packID: "glastonbury-2026"))
        let rows = lineups()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].packID, "glastonbury-2026")
        XCTAssertEqual(rows[0].name, "Glastonbury 2026")
        XCTAssertEqual(rows[0].stageCount, 6)   // 3 stages × 2 days
        XCTAssertEqual(rows[0].setCount, 8)
        XCTAssertEqual(rows[0].sourceLabel, "Test stub")
        // The stored blob round-trips to the same pack — the row IS the wire form.
        XCTAssertEqual(rows[0].pack(), pack)
    }

    func testReinstallReplacesTheRowKeyedByPackID() async throws {
        var pack = FestivalFixtures.glastonbury()
        let installer = FestivalLineupInstaller()
        _ = await installer.install(using: StubProvider(data: try pack.fpackData()), into: context)

        // A lineup revision: same festival slug, new location detail.
        pack.location = "Worthy Farm (revised)"
        _ = await installer.install(using: StubProvider(data: try pack.fpackData()), into: context)

        let rows = lineups()
        XCTAssertEqual(rows.count, 1, "same packID replaces, never duplicates")
        XCTAssertEqual(rows[0].location, "Worthy Farm (revised)")
    }

    // MARK: - Rejection paths (nothing half-installs)

    func testGarbageBytesFailWithTheCodecMessageAndInstallNothing() async {
        let installer = FestivalLineupInstaller()
        let result = await installer.install(using: StubProvider(data: Data("not a pack".utf8)),
                                             into: context)
        XCTAssertNil(result)
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected .failed, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("isn't a Snappet festival pack"), message)
        XCTAssertTrue(lineups().isEmpty)
    }

    func testStructurallyInvalidPackFailsWithTheValidatorMessageVerbatim() async throws {
        // Decodes fine, but Overmono's window is inverted → the validator speaks.
        var pack = FestivalFixtures.glastonbury()
        pack.days[0].stages[1].sets[0] = FestivalSet(
            artist: "Overmono",
            start: FestivalFixtures.date("2026-06-27T23:30"),
            end: FestivalFixtures.date("2026-06-27T23:00"))
        pack.stampContentIdentity()

        let installer = FestivalLineupInstaller()
        let result = await installer.install(using: StubProvider(data: try pack.fpackData()),
                                             into: context)
        XCTAssertNil(result)
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected .failed, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("ends before it starts"), message)
        XCTAssertTrue(lineups().isEmpty)
    }

    func testProviderErrorSurfacesItsLocalizedDescription() async {
        struct FailingProvider: FestivalPackProvider {
            var sourceLabel: String { "Failing" }
            func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
                throw FestivalCatalogError.http(404)
            }
        }
        let installer = FestivalLineupInstaller()
        _ = await installer.install(using: FailingProvider(), into: context)
        guard case .failed(let message) = installer.phase else {
            return XCTFail("expected .failed, got \(installer.phase)")
        }
        XCTAssertTrue(message.contains("HTTP 404"), message)
    }
}
