import XCTest
import HighlightEngine
@testable import Snappet

/// Tests for `HROverlayValues.resolveTile(_:)` — the pure value layer that turns an `HRTile` into the
/// render-ready `ResolvedHRTile` the export burn-in (`StudioOverlays.hrTileLayer`) and the preview both
/// consume. The Core-Animation card itself is device-only; this is the data that drives it.
final class HRTileResolveTests: XCTestCase {

    private func values(maxHR: Double? = 190, restHR: Double? = 60,
                        kcal: Double? = 240, hrv: HRVMetrics = .empty) -> HROverlayValues {
        let samples = [HRPoint(t: 0, bpm: 60), HRPoint(t: 30, bpm: 180), HRPoint(t: 60, bpm: 90)]
        return HROverlayValues(samples: samples, durationSec: 60, maxHR: maxHR, restHR: restHR,
                               kcal: kcal, hrv: hrv)
    }

    /// A tile with **every** metric forced ON — the redesign spawns only a focused set by default, so
    /// these data-driven resolve tests turn them all on to exercise the no-data dropping in isolation.
    private func tileAllOn() -> HRTile {
        var t = HRTile.make(template: .scorebug)
        for i in t.entries.indices { t.entries[i].on = true }
        return t
    }

    func testResolveDropsMetricsWithoutData() throws {
        // No kcal + no RR → calories and HRV have no data and are dropped from the tile.
        let resolved = try XCTUnwrap(values(kcal: nil, hrv: .empty).resolveTile(tileAllOn()))
        XCTAssertFalse(resolved.enabledMetrics.contains(.calories))
        XCTAssertFalse(resolved.enabledMetrics.contains(.hrv))
        XCTAssertTrue(resolved.enabledMetrics.contains(.bpm))
        XCTAssertTrue(resolved.enabledMetrics.contains(.avgHR))
    }

    func testResolveKeepsEveryMetricWithFullData() throws {
        let full = values(hrv: HRVMetrics(rmssd: 42, sdnn: 50, pnn50: 0.2, beatCount: 30))
        let resolved = try XCTUnwrap(full.resolveTile(tileAllOn()))
        // With bounds + kcal + RR every metric resolves, in catalog order.
        XCTAssertEqual(resolved.enabledMetrics, HROverlayMetric.allCases)
    }

    func testResolveReturnsNilWhenNothingToShow() {
        var tile = tileAllOn()
        for i in tile.entries.indices { tile.entries[i].on = false }
        tile.showChart = false
        XCTAssertNil(values().resolveTile(tile))
    }

    func testResolveKeepsChartOnlyTile() throws {
        var tile = tileAllOn()
        for i in tile.entries.indices { tile.entries[i].on = false }
        tile.showChart = true
        let resolved = try XCTUnwrap(values().resolveTile(tile))
        XCTAssertTrue(resolved.enabledMetrics.isEmpty)
        XCTAssertTrue(resolved.showChart)
    }

    func testLiveMetricHasMultipleSegments() throws {
        let resolved = try XCTUnwrap(values().resolveTile(tileAllOn()))
        let bpm = try XCTUnwrap(resolved.metrics.first { $0.metric == .bpm })
        XCTAssertGreaterThan(bpm.segments.count, 1)          // bpm changes over the clip (animated)
        // A static aggregate is a single [0,1] segment.
        let avg = try XCTUnwrap(resolved.metrics.first { $0.metric == .avgHR })
        XCTAssertEqual(avg.segments.count, 1)
    }
}
