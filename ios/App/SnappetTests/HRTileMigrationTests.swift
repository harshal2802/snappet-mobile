import XCTest
import HighlightEngine
@testable import Snappet

/// Tests that legacy free-floating `HROverlayElement` overlays upgrade into a single `HRTile` with
/// **zero data loss** — every element becomes an ON entry preserving its order/flags/colour, the
/// template is inferred from the element count, and the tile's frame is the elements' bounding box.
final class HRTileMigrationTests: XCTestCase {

    private func config(elements: [HROverlayElement], showChart: Bool = false,
                        tile: HRTile? = nil) -> HROverlayConfig {
        HROverlayConfig(normalizedX: 0.5, normalizedY: 0.8, scale: 0.86, colorHex: "#FF3B30",
                        showBPM: true, zoneColored: false, showChart: showChart,
                        elements: elements, tile: tile)
    }

    func testNoMigrationWhenTileAlreadyPresent() {
        let cfg = config(elements: [HROverlayElement(metric: .bpm)], tile: HRTile.make(template: .scorebug))
        XCTAssertNil(HRTileMigration.tile(from: cfg))
    }

    func testNoMigrationWhenNothingToShow() {
        XCTAssertNil(HRTileMigration.tile(from: config(elements: [], showChart: false)))
    }

    func testMigratesElementsPreservingOrderFlagsAndColour() throws {
        let els = [
            HROverlayElement(metric: .maxHR, normalizedX: 0.2, normalizedY: 0.7),
            HROverlayElement(metric: .bpm, normalizedX: 0.6, normalizedY: 0.9, colorHex: "#FF0000"),
        ]
        let tile = try XCTUnwrap(HRTileMigration.tile(from: config(elements: els)))
        // ON entries first, in the elements' order; the rest appended OFF.
        XCTAssertEqual(tile.enabledMetrics, [.maxHR, .bpm])
        XCTAssertEqual(tile.entries.count, HROverlayMetric.allCases.count)
        XCTAssertEqual(tile.entry(for: .bpm)?.colorHex, "#FF0000")    // colour preserved
        XCTAssertTrue(try XCTUnwrap(tile.entry(for: .bpm)).live)       // bpm was live
        // Frame = bounding box of the element positions.
        XCTAssertEqual(tile.center.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(tile.center.y, 0.8, accuracy: 1e-6)
        // 2 elements → hudPill (compact).
        XCTAssertEqual(tile.template, .hudPill)
    }

    func testInferredTemplateByCount() {
        XCTAssertEqual(HRTileMigration.inferredTemplate(elementCount: 1, showChart: true), .chartBanner)
        XCTAssertEqual(HRTileMigration.inferredTemplate(elementCount: 2, showChart: false), .hudPill)
        XCTAssertEqual(HRTileMigration.inferredTemplate(elementCount: 4, showChart: false), .scorebug)
        XCTAssertEqual(HRTileMigration.inferredTemplate(elementCount: 7, showChart: false), .bento)
    }

    func testChartOnlyMigratesToChartBanner() throws {
        let tile = try XCTUnwrap(HRTileMigration.tile(from: config(elements: [], showChart: true)))
        XCTAssertEqual(tile.template, .chartBanner)
        XCTAssertTrue(tile.showChart)
        XCTAssertTrue(tile.enabledMetrics.isEmpty)            // no badges to carry over; just the chart
    }
}
