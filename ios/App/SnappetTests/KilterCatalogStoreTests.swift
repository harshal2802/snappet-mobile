import XCTest
import SQLite3
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

    /// Install a fixture into `store` with a given name/date so library entries are distinguishable.
    @discardableResult
    private func installFixture(into store: KilterCatalogStore, name: String, at date: Date) throws -> String {
        let url = try KilterCatalogFixture.temporaryBuild()
        let v = try KilterCatalogValidator.validate(url)
        return try store.install(from: url, meta: KilterCatalogMeta(
            version: v.version, climbCount: v.climbCount, sizeBytes: v.sizeBytes,
            source: "Test", installedAt: date, name: name))
    }

    func testLibraryHoldsMultipleCatalogsNewestActive() throws {
        let store = tempStore()
        let idA = try installFixture(into: store, name: "A", at: Date(timeIntervalSince1970: 1000))
        let idB = try installFixture(into: store, name: "B", at: Date(timeIntervalSince1970: 2000))

        XCTAssertEqual(store.installed().count, 2)
        XCTAssertEqual(store.installed().first?.meta.name, "B", "most-recent first")
        XCTAssertEqual(store.activeCatalogId, idB, "a fresh install becomes active")

        try store.setActive(id: idA)
        XCTAssertEqual(store.metadata()?.name, "A")
        XCTAssertEqual(store.activeCatalogId, idA)
    }

    func testRemovingActiveFallsBackToAnother() throws {
        let store = tempStore()
        let idA = try installFixture(into: store, name: "A", at: Date(timeIntervalSince1970: 1000))
        let idB = try installFixture(into: store, name: "B", at: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(store.activeCatalogId, idB)

        try store.remove(id: idB)
        XCTAssertEqual(store.installed().count, 1)
        XCTAssertEqual(store.activeCatalogId, idA, "removing the active catalog promotes the remaining one")
        XCTAssertTrue(store.isInstalled)

        try store.remove(id: idA)
        XCTAssertTrue(store.installed().isEmpty)
        XCTAssertFalse(store.isInstalled)
        XCTAssertNil(store.activeCatalogId)
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

    /// Board-size LED selection: each `product_size` addresses its LEDs differently, so `holds(sizeId:)`
    /// must use the *selected* size — sending another size's positions lights wrong/shifted holds (the
    /// real-hardware bug). Also proves the board payload uses `led_color`, not the on-screen
    /// `screen_color`. The fixture gives layout 1 two sizes (size 2 offset by 1000) and a `start` role
    /// whose `led_color` (00FF00) differs from its `screen_color` (00DD00).
    func testBoardSizeSelectsLEDMapAndUsesLedColor() throws {
        let store = KilterCatalogStore.shared
        let url = try KilterCatalogFixture.temporaryBuild()
        let validated = try KilterCatalogValidator.validate(url)
        try store.install(from: url, meta: KilterCatalogMeta(
            version: validated.version, climbCount: validated.climbCount,
            sizeBytes: validated.sizeBytes, source: "Test", installedAt: .now))
        defer { try? store.clear(); KilterCatalog.shared.reload() }
        KilterCatalog.shared.reload()
        let cat = KilterCatalog.shared

        XCTAssertEqual(cat.sizes(forLayout: 1).map(\.id).sorted(), [1, 2, 3], "layout 1 offers three sizes")
        XCTAssertEqual(cat.defaultSizeId(forLayout: 1), 1, "smallest product_size_id is the default")

        guard let climb = cat.climb("11111111-1111-4111-8111-111111111111") else {
            return XCTFail("fixture climb Alpha missing")
        }
        // Same climb, different boards → different LED addresses (size 2 is offset by 1000).
        let s1 = cat.holds(for: climb, sizeId: 1).compactMap(\.ledPosition).sorted()
        let s2 = cat.holds(for: climb, sizeId: 2).compactMap(\.ledPosition).sorted()
        XCTAssertEqual(s1, [1, 13, 25])
        XCTAssertEqual(s2, [1001, 1013, 1025])
        // An unset (0) or stale (foreign) size falls back to the layout's smallest — deterministic, no crash.
        XCTAssertEqual(cat.holds(for: climb, sizeId: 0).compactMap(\.ledPosition).sorted(), s1)
        XCTAssertEqual(cat.holds(for: climb, sizeId: 999).compactMap(\.ledPosition).sorted(), s1)

        guard let start = cat.holds(for: climb, sizeId: 1).first(where: { $0.role == "start" }) else {
            return XCTFail("expected a start hold")
        }
        XCTAssertEqual(start.colorHex, "00DD00", "on-screen render keeps screen_color")
        XCTAssertEqual(start.ledColorHex, "00FF00", "board payload uses led_color")
    }

    /// Regression / parity: an older or hand-rolled catalog can lack the (non-required) `product_sizes`
    /// table yet still pass validation. `sizes(forLayout:)` must **degrade** to bare ids, not crash —
    /// Android's rawQuery throws on a missing table where iOS's query() silently yields none, so this
    /// pins the contract both platforms must honor (mirrored by `KilterCatalogStoreTest` on Android).
    func testSizesDegradeWhenProductSizesTableAbsent() throws {
        let url = try KilterCatalogFixture.temporaryBuild()
        // Drop product_sizes to simulate the older-catalog case (still valid — it isn't required).
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "DROP TABLE product_sizes", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let store = KilterCatalogStore.shared
        let validated = try KilterCatalogValidator.validate(url)   // passes — product_sizes not required
        try store.install(from: url, meta: KilterCatalogMeta(
            version: validated.version, climbCount: validated.climbCount,
            sizeBytes: validated.sizeBytes, source: "Test", installedAt: .now))
        defer { try? store.clear(); KilterCatalog.shared.reload() }
        KilterCatalog.shared.reload()
        let cat = KilterCatalog.shared

        // Degrades to bare ids from product_sizes_layouts_sets instead of crashing.
        XCTAssertEqual(cat.sizes(forLayout: 1).map(\.id).sorted(), [1, 2, 3])
        // The LED map still resolves for a chosen size (the holds path queries leds, not product_sizes).
        guard let climb = cat.climb("11111111-1111-4111-8111-111111111111") else {
            return XCTFail("fixture climb Alpha missing")
        }
        XCTAssertEqual(cat.holds(for: climb, sizeId: 2).compactMap(\.ledPosition).sorted(), [1001, 1013, 1025])
    }

    /// The on-screen board must track the **selected size**: `boardGeometry(forLayout:sizeId:)` renders
    /// only the holes wired for that `product_size`, so a smaller board reads shorter (fewer holes,
    /// taller aspect) — and the lit holds normalize to the same extent, so a hold above the smaller
    /// board clamps onto its top edge. The fixture's size 3 (5×3) wires the bottom three rows; sizes
    /// 1/2 (5×5) wire all 25.
    func testBoardGeometryAndHoldsTrackSelectedSize() throws {
        let store = KilterCatalogStore.shared
        let url = try KilterCatalogFixture.temporaryBuild()
        let validated = try KilterCatalogValidator.validate(url)
        try store.install(from: url, meta: KilterCatalogMeta(
            version: validated.version, climbCount: validated.climbCount,
            sizeBytes: validated.sizeBytes, source: "Test", installedAt: .now))
        defer { try? store.clear(); KilterCatalog.shared.reload() }
        KilterCatalog.shared.reload()
        let cat = KilterCatalog.shared

        let full = cat.boardGeometry(forLayout: 1, sizeId: 1)   // 5×5
        let mini = cat.boardGeometry(forLayout: 1, sizeId: 3)   // 5×3 (bottom three rows)
        XCTAssertEqual(full.grid.count, 25, "the full board shows every hole")
        XCTAssertEqual(mini.grid.count, 15, "the smaller board renders only its wired holes")
        XCTAssertEqual(full.aspect, 1.0, accuracy: 0.001, "5×5 → 16/16")
        XCTAssertEqual(mini.aspect, 2.0, accuracy: 0.001, "5 wide × 3 tall → 16/8")
        // sizeId 0 = whole layout; an invalid/foreign size falls back to the whole layout (no crash).
        XCTAssertEqual(cat.boardGeometry(forLayout: 1, sizeId: 0).grid.count, 25)
        XCTAssertEqual(cat.boardGeometry(forLayout: 1, sizeId: 999).grid.count, 25)

        // Holds line up with the grid: Alpha's top hole (placement 25, board y 20 — above the 5×3 board)
        // clamps to the mini board's top edge (view y 0); its bottom hole (placement 1) sits at the floor.
        guard let climb = cat.climb("11111111-1111-4111-8111-111111111111") else {
            return XCTFail("fixture climb Alpha missing")
        }
        let mh = cat.holds(for: climb, sizeId: 3)
        XCTAssertEqual(mh.first { $0.placementId == 25 }?.y ?? -1, 0.0, accuracy: 0.001,
                       "a hold above the smaller board clamps to its top edge")
        XCTAssertEqual(mh.first { $0.placementId == 1 }?.y ?? -1, 1.0, accuracy: 0.001,
                       "the bottom hole sits on the floor")

        // Holds line up with the grid: at full size every lit hold sits exactly on a grid hole (so an
        // x-normalization slip would leave a hold off the grid).
        for h in cat.holds(for: climb, sizeId: 1) {
            XCTAssertTrue(full.grid.contains { abs($0.x - h.x) < 0.001 && abs($0.y - h.y) < 0.001 },
                          "lit hold \(h.placementId) at (\(h.x), \(h.y)) must coincide with a grid hole")
        }
        // Alpha's holds are all on the board diagonal (which can't catch an x↔y swap) — use an OFF-
        // diagonal hold (Charlie's placement 3 = board (12, 4) → x 0.5, y 1.0) to pin x independently.
        guard let charlie = cat.climb("33333333-3333-4333-8333-333333333333") else {
            return XCTFail("fixture climb Charlie missing")
        }
        let p3 = cat.holds(for: charlie, sizeId: 1).first { $0.placementId == 3 }
        XCTAssertEqual(p3?.x ?? -1, 0.5, accuracy: 0.001, "x normalizes independently of y")
        XCTAssertEqual(p3?.y ?? -1, 1.0, accuracy: 0.001)
    }

    /// Color-blind support: each role maps to a distinct marker shape (a redundant channel alongside
    /// color), so the four roles get four shapes that stay separable in grayscale. Pure mapping — no
    /// store, no device. Mirrored by Android `KilterHoldShapeTest`.
    func testHoldShapeMapsEachRoleToADistinctShape() {
        XCTAssertEqual(KilterHoldShape.forRole("start"), .triangle)
        XCTAssertEqual(KilterHoldShape.forRole("middle"), .circle)
        XCTAssertEqual(KilterHoldShape.forRole("finish"), .square)
        XCTAssertEqual(KilterHoldShape.forRole("foot"), .diamond)
        XCTAssertEqual(KilterHoldShape.forRole("hold"), .circle, "an unknown role falls back to a circle")
        let roleShapes = ["start", "middle", "finish", "foot"].map(KilterHoldShape.forRole)
        XCTAssertEqual(Set(roleShapes).count, 4, "the four roles must be four distinct shapes")
    }
}
