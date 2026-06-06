import XCTest
@testable import Snappet

/// Unit coverage for the opt-in catalog plumbing (issue #42): the synthetic fixture builds, the
/// validator accepts it and rejects junk with a derived/deterministic version, the store
/// installs/clears with a round-tripped meta sidecar, and an installed fixture actually drives the
/// read-only `KilterCatalog`. Runs on the simulator host (SQLite is available there) — no device, no
/// network, and no Aurora data (every row is authored by `KilterCatalogFixture`).
@MainActor
final class KilterCatalogStoreTests: XCTestCase {

    private func tempStore() -> KilterCatalogStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kilter-store-\(UUID().uuidString)", isDirectory: true)
        return KilterCatalogStore(directory: dir)
    }

    func testFixtureValidatesWithExpectedCounts() throws {
        let url = try KilterCatalogFixture.temporaryBuild()
        defer { try? FileManager.default.removeItem(at: url) }
        let validated = try KilterCatalogValidator.validate(url)
        XCTAssertEqual(validated.climbCount, 4)
        XCTAssertGreaterThan(validated.sizeBytes, 0)
        XCTAssertFalse(validated.version.isEmpty)
    }

    func testVersionIsDeterministic() throws {
        let a = try KilterCatalogValidator.validate(KilterCatalogFixture.temporaryBuild())
        let b = try KilterCatalogValidator.validate(KilterCatalogFixture.temporaryBuild())
        XCTAssertEqual(a.version, b.version, "The same synthetic catalog must derive the same version")
    }

    func testValidatorRejectsNonCatalog() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-catalog-\(UUID().uuidString).sqlite3")
        try Data("this is not a sqlite database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try KilterCatalogValidator.validate(url)) { error in
            guard case KilterCatalogValidator.Failure.missingTables = error else {
                return XCTFail("expected missingTables, got \(error)")
            }
        }
    }

    func testInstallThenClearRoundTrips() throws {
        let store = tempStore()
        XCTAssertFalse(store.isInstalled)

        let url = try KilterCatalogFixture.temporaryBuild()
        let validated = try KilterCatalogValidator.validate(url)
        let meta = KilterCatalogMeta(version: validated.version, climbCount: validated.climbCount,
                                     sizeBytes: validated.sizeBytes, source: "Test", installedAt: .now)
        try store.install(from: url, meta: meta)

        XCTAssertTrue(store.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "install consumes the temp file (moves it into place)")
        XCTAssertEqual(store.metadata()?.climbCount, 4)
        XCTAssertEqual(store.metadata()?.version, validated.version)

        try store.clear()
        XCTAssertFalse(store.isInstalled)
        XCTAssertNil(store.metadata())
    }

    /// Integration: install the fixture into the shared store, reload the reader, and confirm it
    /// browses + decodes holds — the closest off-device proof that the import path feeds `KilterCatalog`
    /// exactly as the old bundled asset did. Cleans up the shared store afterward.
    func testInstalledFixtureDrivesTheReader() throws {
        let store = KilterCatalogStore.shared
        let url = try KilterCatalogFixture.temporaryBuild()
        let validated = try KilterCatalogValidator.validate(url)
        try store.install(from: url, meta: KilterCatalogMeta(
            version: validated.version, climbCount: validated.climbCount,
            sizeBytes: validated.sizeBytes, source: "Test", installedAt: .now))
        defer { try? store.clear(); KilterCatalog.shared.reload() }

        KilterCatalog.shared.reload()
        XCTAssertTrue(KilterCatalog.shared.isAvailable)
        XCTAssertEqual(KilterCatalog.shared.layouts().count, 1, "only layout 1 has listed climbs")

        let items = KilterCatalog.shared.list(layoutId: 1, angle: 40,
                                              minDifficulty: 1, maxDifficulty: 39)
        XCTAssertEqual(items.count, 4)

        guard let first = items.first, let climb = KilterCatalog.shared.climb(first.uuid) else {
            return XCTFail("expected to open a climb from the fixture")
        }
        XCTAssertFalse(KilterCatalog.shared.holds(for: climb).isEmpty, "frames should decode to holds")
    }
}
