import XCTest
@testable import Snappet

/// Unit coverage for the in-app **hosted-catalog download**'s pure half (issue #42 Phase 2): the
/// on-device gunzip and the filtered-catalog build that trims a full board dataset into a small,
/// importable file (mirrors the web Board Explorer's `exportDb.ts`). The download is the impure edge
/// (verified on-device); here the `KilterCatalogFixture` stands in for a freshly-downloaded source DB.
@MainActor
final class KilterAuroraSyncTests: XCTestCase {

    // MARK: - gunzip

    /// A real gzip stream (`printf … | gzip`) must inflate back to the original bytes via the zlib path.
    func testGunzipRoundTrips() throws {
        let b64 = "H4sIAKHhI2oAA8tIzcnJV8jOzClJLVJIL82ryixQKMovzUvRLSkCMg2NjE1MFQ7vyTu8Pjk/JRUADtiWuy4AAAA="
        let expected = "hello kilter gunzip round-trip 12345 ünïcode"
        let gz = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gz")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: gz); try? FileManager.default.removeItem(at: out) }
        try Data(base64Encoded: b64)!.write(to: gz)

        try HostedCatalogClient().gunzip(gz, to: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), expected)
    }

    // MARK: - filtered build (mirrors exportDb.ts)

    /// Build a filtered catalog from a synthetic full source (the fixture) and read it back through the
    /// real `KilterCatalog`. The fixture has 4 listed single-frame climbs on layout 1.
    private func filteredFromFixture(_ filter: CatalogFilter) throws -> URL {
        let source = try KilterCatalogFixture.temporaryBuild()
        defer { try? FileManager.default.removeItem(at: source) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite3")
        try HostedCatalogClient().buildFilteredCatalog(sourcePath: source.path, filter: filter, outPath: out.path)
        return out
    }

    func testFilteredBuildKeepsMatchingClimbsAndReads() throws {
        var f = CatalogFilter()
        f.layoutIds = [1]; f.maxClimbs = 100   // keep all four
        let out = try filteredFromFixture(f)
        defer { try? FileManager.default.removeItem(at: out) }

        let validated = try KilterCatalogValidator.validate(out)
        XCTAssertEqual(validated.climbCount, 4)

        let store = KilterCatalogStore.shared
        try store.install(from: out, meta: KilterCatalogMeta(
            version: validated.version, climbCount: validated.climbCount,
            sizeBytes: validated.sizeBytes, source: "Test", installedAt: .now))
        defer { try? store.clear(); KilterCatalog.shared.reload() }
        KilterCatalog.shared.reload()

        XCTAssertTrue(KilterCatalog.shared.isAvailable)
        let items = KilterCatalog.shared.list(layoutId: 1, angle: 40, minDifficulty: 1, maxDifficulty: 39)
        XCTAssertEqual(items.count, 4, "all four fixture climbs survive a non-narrowing filter")
        // Geometry copied whole → frames still decode to holds.
        guard let climb = KilterCatalog.shared.climb(items[0].uuid) else { return XCTFail("no climb") }
        XCTAssertFalse(KilterCatalog.shared.holds(for: climb).isEmpty)
    }

    func testMaxClimbsCapKeepsOnlyTopMostClimbed() throws {
        var f = CatalogFilter()
        f.layoutIds = [1]; f.maxClimbs = 2     // keep only the two most-climbed
        let out = try filteredFromFixture(f)
        defer { try? FileManager.default.removeItem(at: out) }
        let validated = try KilterCatalogValidator.validate(out)
        XCTAssertEqual(validated.climbCount, 2, "the top-N cap trims to the most-climbed problems")
    }

    func testEmptyMatchThrowsRatherThanInstallingJunk() throws {
        var f = CatalogFilter()
        f.layoutIds = [8]      // the fixture has no layout-8 climbs
        XCTAssertThrowsError(try filteredFromFixture(f)) { error in
            guard case HostedCatalogError.noCatalogData = error else {
                return XCTFail("expected noCatalogData, got \(error)")
            }
        }
    }

    func testBenchmarkOnlyExcludesNonBenchmarks() throws {
        var f = CatalogFilter()
        f.layoutIds = [1]; f.benchmarkOnly = true   // fixture stats carry no benchmark_difficulty
        XCTAssertThrowsError(try filteredFromFixture(f)) { error in
            guard case HostedCatalogError.noCatalogData = error else {
                return XCTFail("expected noCatalogData, got \(error)")
            }
        }
    }
}
