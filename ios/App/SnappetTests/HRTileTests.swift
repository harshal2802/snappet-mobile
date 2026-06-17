import XCTest
import HighlightEngine
@testable import Snappet

/// Tests for the unified HR stat **tile** model (the overlay redesign): templates + the all-on-by-
/// default per-metric toggles + template switching that preserves the user's choices. Pure value
/// types → no simulator.
final class HRTileTests: XCTestCase {

    func testTemplateSpawnsFocusedLegibleSet() {
        let tile = HRTile.make(template: .bento)
        // One entry per known metric, in catalog order (the rest exist, just OFF)…
        XCTAssertEqual(tile.entries.map(\.metric), HROverlayMetric.allCases)
        XCTAssertEqual(tile.entries.count, HROverlayMetric.allCases.count)
        // …but the redesign spawns the template's FOCUSED legible set ON — never all 10 at once (the
        // anti-crop hierarchy: one hero + secondary + a few tertiary).
        XCTAssertEqual(tile.enabledMetrics, HRTileTemplate.bento.spawnMetrics)
        XCTAssertLessThan(tile.enabledMetrics.count, HROverlayMetric.allCases.count)
    }

    func testCompactTemplateSpawnsLeanestSet() {
        let tile = HRTile.make(template: .hudPill)
        XCTAssertEqual(tile.enabledMetrics, [.bpm, .zone])         // the HUD pill spawns the leanest set
        XCTAssertEqual(tile.entries.count, HROverlayMetric.allCases.count)  // the rest exist, just OFF
        XCTAssertFalse(tile.entry(for: .calories) != nil)         // calories is present but OFF
    }

    func testDefaultTemplateIsGlassHeroWithChart() {
        // The redesign default: Glass Hero Card (`hero`) with the sparkline ON, spawning a focused set.
        let tile = HRTile.make(template: .hero)
        XCTAssertEqual(tile.enabledMetrics, [.bpm, .zone, .avgHR, .maxHR, .calories])
        XCTAssertTrue(tile.showChart)
    }

    func testEnabledMetricsFiltersOffEntries() {
        var tile = HRTile.make(template: .scorebug)
        // `enabledMetrics` is always in catalog (allCases) order — `spawnMetrics` only decides the SET
        // that's ON, not the order — so compare as a set.
        let spawn = Set(HRTileTemplate.scorebug.spawnMetrics)
        XCTAssertEqual(Set(tile.enabledMetrics), spawn)
        // Toggle a spawned metric (avgHR) OFF.
        if let idx = tile.entries.firstIndex(where: { $0.metric == .avgHR }) {
            tile.entries[idx].on = false
        }
        XCTAssertFalse(tile.enabledMetrics.contains(.avgHR))
        XCTAssertEqual(tile.enabledMetrics.count, spawn.count - 1)
    }

    func testSwitchingTemplatePreservesToggles() {
        let hero = HRTile.make(template: .hero)               // hero's focused set ON
        let switched = hero.switchingTemplate(to: .bento)
        XCTAssertEqual(switched.template, .bento)             // template changed…
        XCTAssertEqual(switched.enabledMetrics, hero.enabledMetrics) // …but the user's toggles are kept (NOT reset)
    }

    func testMakeUsesTemplateDefaultFrameAndChart() {
        let banner = HRTile.make(template: .chartBanner)
        XCTAssertTrue(banner.showChart)                       // the chart template starts with the chart on
        XCTAssertEqual(banner.center, HRTileTemplate.chartBanner.defaultCenter)
        XCTAssertEqual(banner.size, HRTileTemplate.chartBanner.defaultSize)

        let rail = HRTile.make(template: .list)               // the Rail defaults the chart OFF
        XCTAssertFalse(rail.showChart)
    }

    func testEveryMetricHasAPlainExplanationAndOpacityDefaultsOpaque() {
        for m in HROverlayMetric.allCases {
            XCTAssertFalse(m.explanation.isEmpty, "\(m) needs a plain-English explanation for the builder")
        }
        XCTAssertEqual(HRTile.make(template: .hero).opacity, 1.0, accuracy: 1e-9)   // opaque by default
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
