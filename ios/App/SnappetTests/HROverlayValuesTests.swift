import XCTest
import HighlightEngine
@testable import Snappet

/// Tests for the configurable HR/fitness overlay (prompt 28): the metric capabilities and the pure
/// value resolver (static aggregates, live-at-playhead, and the animated-export segments). The
/// Core-Animation burn-in + the SwiftUI preview are device-only; this is the value logic that drives
/// both so the exported file matches the preview.
final class HROverlayModelTests: XCTestCase {

    func testLiveAndAnimationCapabilities() {
        // Time-varying metrics support live + animation.
        for m in [HROverlayMetric.bpm, .zone, .hrr, .recovery] {
            XCTAssertTrue(m.supportsLive, "\(m) should support live")
            XCTAssertTrue(m.supportsAnimation, "\(m) should support animation")
        }
        // Clip aggregates are static only.
        for m in [HROverlayMetric.avgHR, .maxHR, .redline, .strain, .hrv, .calories] {
            XCTAssertFalse(m.supportsLive, "\(m) should be static")
            XCTAssertFalse(m.supportsAnimation, "\(m) should not animate")
        }
    }

    func testElementForcesLiveOffForStaticMetrics() {
        var el = HROverlayElement(metric: .avgHR)
        el.live = true; el.animated = true       // user (or stale data) sets them…
        XCTAssertFalse(el.isLive)                  // …but a static metric is never live
        XCTAssertFalse(el.isAnimated)
    }

    func testElementDefaultsLiveMetricToLiveAnimated() {
        let el = HROverlayElement(metric: .bpm)
        XCTAssertTrue(el.isLive)
        XCTAssertTrue(el.isAnimated)
    }

    func testBackCompatConfigDecodesWithoutElements() throws {
        // A config JSON saved before this feature (no `elements` key) must decode with [].
        let legacy = "{\"normalizedX\":0.5,\"normalizedY\":0.8,\"scale\":0.86,\"colorHex\":\"#FF3B30\",\"showBPM\":true,\"zoneColored\":false}"
        let cfg = try JSONDecoder().decode(HROverlayConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(cfg.elements.isEmpty)
    }
}

final class HROverlayValuesTests: XCTestCase {

    // A rising-then-falling clip: 0s→60s, 60→180 bpm and back. rest 60 / max 190.
    private func values(maxHR: Double? = 190, restHR: Double? = 60,
                        kcal: Double? = 240, hrv: HRVMetrics = .empty) -> HROverlayValues {
        let samples = [HRPoint(t: 0, bpm: 60), HRPoint(t: 30, bpm: 180), HRPoint(t: 60, bpm: 90)]
        return HROverlayValues(samples: samples, durationSec: 60, maxHR: maxHR, restHR: restHR,
                               kcal: kcal, hrv: hrv)
    }

    func testStaticAggregates() {
        let v = values()
        XCTAssertNotNil(v.staticValue(.avgHR, fallbackHex: "#FFFFFF"))
        XCTAssertNotNil(v.staticValue(.maxHR, fallbackHex: "#FFFFFF"))
        XCTAssertTrue(try XCTUnwrap(v.staticValue(.maxHR, fallbackHex: "#FFFFFF")).text.contains("180"))
        XCTAssertNotNil(v.staticValue(.redline, fallbackHex: "#FFFFFF"))
        XCTAssertNotNil(v.staticValue(.strain, fallbackHex: "#FFFFFF"))
    }

    func testCaloriesAndHRVGating() {
        // Calories present only with a kcal estimate; HRV only with RR-derived RMSSD.
        XCTAssertNotNil(values(kcal: 240).staticValue(.calories, fallbackHex: "#FFF"))
        XCTAssertNil(values(kcal: nil).staticValue(.calories, fallbackHex: "#FFF"))
        let withHRV = values(hrv: HRVMetrics(rmssd: 42, sdnn: 50, pnn50: 0.2, beatCount: 30))
        XCTAssertEqual(try XCTUnwrap(withHRV.staticValue(.hrv, fallbackHex: "#FFF")).text, "HRV 42 ms")
        XCTAssertNil(values(hrv: .empty).staticValue(.hrv, fallbackHex: "#FFF"))
    }

    func testLiveBpmTracksPlayhead() throws {
        let v = values()
        // The live bpm tracks the playhead over the SAME dense series the curve+dot draw from (prompt 101):
        // near the mid-clip peak (t≈30 → fraction 0.5) it's high (lightly smoothed below the raw 180 peak),
        // near the start it's low, and it changes across the clip. The raw 180 peak is preserved in the
        // PEAK aggregate (testChartSamplesDensifyButAggregatesStayRaw), not shaved off it.
        let mid = try XCTUnwrap(v.bpm(atFraction: 0.5))
        let start = try XCTUnwrap(v.bpm(atFraction: 0.0))
        XCTAssertGreaterThan(mid, 170)            // near the 180 peak
        XCTAssertLessThan(start, 75)              // near the 60 start
        XCTAssertGreaterThan(mid - start, 50)     // clearly rises across the clip
        // The live Reading text still updates over the clip.
        let midText = try XCTUnwrap(v.live(.bpm, atFraction: 0.5, fallbackHex: "#FFF"))
        let startText = try XCTUnwrap(v.live(.bpm, atFraction: 0.0, fallbackHex: "#FFF"))
        XCTAssertNotEqual(startText.text, midText.text)
    }

    func testLiveHRRNilWithoutBounds() {
        // No rest/max → no %HRR (honest gating, like the rest of the suite).
        XCTAssertNil(values(maxHR: nil, restHR: nil).live(.hrr, atFraction: 0.5, fallbackHex: "#FFF"))
    }

    func testAnimatedLiveElementHasMultipleSegmentsStaticHasOne() {
        let v = values()
        let liveEl = HROverlayElement(metric: .bpm)                    // live + animated by default
        let segs = v.segments(for: liveEl)
        XCTAssertGreaterThan(segs.count, 1)                            // the reading changes over time
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last?.end, 1)                              // tiled to cover the whole clip
        // A static metric → exactly one segment spanning the clip.
        let staticEl = HROverlayElement(metric: .avgHR)
        XCTAssertEqual(v.segments(for: staticEl).count, 1)
    }

    func testLiveButNotAnimatedIsSingleSegment() {
        var el = HROverlayElement(metric: .bpm)
        el.animated = false                                            // live in preview, fixed in export
        XCTAssertEqual(values().segments(for: el).count, 1)
    }

    // MARK: - Dense chart series + honest sparse styling (prompt 101)

    func testChartSamplesDensifyButAggregatesStayRaw() {
        let v = values()   // 3 raw samples over 60s, peak 180
        XCTAssertGreaterThan(v.chartSamples.count, v.samples.count, "chart series should be densified")
        XCTAssertEqual(v.chartSamples.last!.t, 60, accuracy: 1e-6, "endpoints span the window for fraction alignment")
        // PEAK/AVG remain from the RAW samples — smoothing the drawn curve must not shave them.
        XCTAssertEqual(v.rawPeakBpm ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(v.staticValue(.maxHR, fallbackHex: "#FFFFFF")?.value, "180")
        XCTAssertEqual(v.staticValue(.avgHR, fallbackHex: "#FFFFFF")?.value, "110")   // (60+180+90)/3
    }

    func testIsSparseChartFlagsTwoPointWindow() {
        // Two samples bracketing a 30s clip → interpolation-dominated → dashed (sparse) styling.
        let sparse = HROverlayValues(samples: [HRPoint(t: 0, bpm: 135), HRPoint(t: 30, bpm: 139)],
                                     durationSec: 30, maxHR: 190, restHR: 60)
        XCTAssertTrue(sparse.isSparseChart)
        // A ~1 Hz window is a measured curve → solid (not sparse).
        let dense = HROverlayValues(samples: (0...30).map { HRPoint(t: Double($0), bpm: 130) },
                                    durationSec: 30, maxHR: 190, restHR: 60)
        XCTAssertFalse(dense.isSparseChart)
    }
}
