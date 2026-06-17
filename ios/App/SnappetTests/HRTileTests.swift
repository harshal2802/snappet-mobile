import XCTest
import HighlightEngine
@testable import Snappet

/// Tests for the unified HR stat **tile** model (the overlay redesign): templates + the all-on-by-
/// default per-metric toggles + template switching that preserves the user's choices. Pure value
/// types → no simulator.
final class HRTileTests: XCTestCase {

    func testDetailedTemplateSpawnsAllMetricsOn() {
        let tile = HRTile.make(template: .bento)
        // One entry per known metric, in catalog order…
        XCTAssertEqual(tile.entries.map(\.metric), HROverlayMetric.allCases)
        // …and a detailed template starts with every metric ON ("all selected by default").
        XCTAssertTrue(tile.entries.allSatisfy(\.on))
        XCTAssertEqual(tile.enabledMetrics, HROverlayMetric.allCases)
    }

    func testCompactTemplateSpawnsFocusedSet() {
        let tile = HRTile.make(template: .hero)
        XCTAssertEqual(tile.enabledMetrics, [.bpm, .zone])         // hero/pill spawn a focused set
        XCTAssertEqual(tile.entries.count, HROverlayMetric.allCases.count)  // the rest exist, just OFF
        XCTAssertFalse(tile.entry(for: .calories) != nil)         // calories is present but OFF
    }

    func testEnabledMetricsFiltersOffEntries() {
        var tile = HRTile.make(template: .scorebug)
        XCTAssertEqual(tile.enabledMetrics.count, HROverlayMetric.allCases.count)
        // Toggle calories OFF.
        if let idx = tile.entries.firstIndex(where: { $0.metric == .calories }) {
            tile.entries[idx].on = false
        }
        XCTAssertFalse(tile.enabledMetrics.contains(.calories))
        XCTAssertEqual(tile.enabledMetrics.count, HROverlayMetric.allCases.count - 1)
    }

    func testSwitchingTemplatePreservesToggles() {
        let hero = HRTile.make(template: .hero)               // only bpm + zone ON
        let switched = hero.switchingTemplate(to: .bento)
        XCTAssertEqual(switched.template, .bento)             // template changed…
        XCTAssertEqual(switched.enabledMetrics, [.bpm, .zone]) // …but the user's toggles are kept (NOT reset)
    }

    func testMakeUsesTemplateDefaultFrameAndChart() {
        let banner = HRTile.make(template: .chartBanner)
        XCTAssertTrue(banner.showChart)                       // the chart template starts with the chart on
        XCTAssertEqual(banner.center, HRTileTemplate.chartBanner.defaultCenter)
        XCTAssertEqual(banner.size, HRTileTemplate.chartBanner.defaultSize)

        let strip = HRTile.make(template: .scorebug)
        XCTAssertFalse(strip.showChart)
    }

    func testSizeClampsToLegibleMinimums() {
        var tile = HRTile.make(template: .scorebug)
        tile.size = CGSize(width: 0.01, height: 0.01)         // absurdly tiny
        XCTAssertEqual(tile.width, HRTile.minWidth, accuracy: 1e-9)
        XCTAssertEqual(tile.height, HRTile.minHeight, accuracy: 1e-9)
    }

    func testMetricEntryForcesLiveOffForStaticMetrics() {
        var e = HRTileMetricEntry(metric: .avgHR)
        e.live = true; e.animated = true                     // a static aggregate is never live…
        XCTAssertFalse(e.isLive)
        XCTAssertFalse(e.isAnimated)
        let live = HRTileMetricEntry(metric: .bpm)           // …a time-varying metric defaults live+animated
        XCTAssertTrue(live.isLive)
        XCTAssertTrue(live.isAnimated)
    }
}
