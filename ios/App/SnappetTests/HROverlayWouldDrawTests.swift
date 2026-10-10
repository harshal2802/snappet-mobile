import XCTest
@testable import Snappet

/// Clips perf 2026-10-06: `wouldDraw` must give exactly the answer `resolveTile != nil` gives — it replaced
/// that call on the per-clip feed path (5.7 s → fast) — for every design, every single-stat tile, chart
/// on/off, live/animated, with and without a resting HR, sparse and empty windows.
final class HROverlayWouldDrawTests: XCTestCase {

    private func values(_ samples: [HRPoint], rest: Double?) -> HROverlayValues {
        HROverlayValues(samples: samples, durationSec: samples.last?.t ?? 10, maxHR: 190, restHR: rest)
    }

    func testMatchesResolveTileEverywhere() {
        let dense = (0...30).map { HRPoint(t: Double($0), bpm: 120 + Double($0)) }
        let sparse = [HRPoint(t: 0, bpm: 130), HRPoint(t: 12, bpm: 150)]
        let windows: [[HRPoint]] = [dense, sparse, []]
        var cases = 0
        for samples in windows {
            for rest in [Double?.none, 60] {
                let v = values(samples, rest: rest)
                var tiles = HRTileTemplate.allCases.map { HRTile.make(template: $0) }
                // Every single-stat tile, chart off, in each live/animated combination.
                for metric in HROverlayMetric.allCases {
                    for (live, animated) in [(false, false), (true, false), (true, true)] {
                        var t = HRTile.make(template: .hudPill)
                        t.showChart = false
                        t.entries = t.entries.map { var e = $0; e.on = e.metric == metric; e.live = live; e.animated = animated; return e }
                        tiles.append(t)
                    }
                }
                for t in tiles {
                    for chart in [true, false] {
                        var tt = t; tt.showChart = chart
                        XCTAssertEqual(v.wouldDraw(tt), v.resolveTile(tt) != nil,
                                       "\(tt.templateRaw) chart=\(chart) on=\(tt.enabledMetrics) rest=\(String(describing: rest)) n=\(samples.count)")
                        cases += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 100)
    }
}
