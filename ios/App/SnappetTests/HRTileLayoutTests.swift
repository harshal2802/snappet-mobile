import XCTest
import HighlightEngine
@testable import Snappet

/// Tests for the pure `HRTileLayout` — the single source of truth shared by the SwiftUI preview and
/// the Core-Animation export burn-in. Asserts the per-template placement invariants (hero placement,
/// reflow-drop, grid column reflow, single-column truncation, ring collapse), the 11 pt font floor,
/// determinism, and order preservation. No simulator.
final class HRTileLayoutTests: XCTestCase {

    private let all = HROverlayMetric.allCases

    private func fields(_ r: HRTileLayout.Result) -> [HRTileLayout.MetricSlot] {
        r.slots.filter { $0.role == .field }
    }

    // MARK: Scorebug

    func testScorebugPlacesLeadHeroLeftmostAndLargest() {
        let r = HRTileLayout.layout(template: .scorebug, enabledMetrics: all,
                                    tileRect: CGRect(x: 0, y: 0, width: 1000, height: 140), hasChart: false)
        let first = try! XCTUnwrap(r.slots.first)
        XCTAssertEqual(first.metric, .bpm)               // the lead is bpm
        XCTAssertEqual(first.role, .hero)
        // Hero font is strictly the largest…
        XCTAssertTrue(r.slots.dropFirst().allSatisfy { first.fontSize >= $0.fontSize })
        XCTAssertGreaterThan(first.fontSize, r.slots.dropFirst().map(\.fontSize).max() ?? 0)
        // …and leftmost.
        XCTAssertEqual(first.frame.minX, r.slots.map { $0.frame.minX }.min())
    }

    func testScorebugDropsTrailingMetricsWhenNarrowKeepingBpmZone() {
        let narrow = HRTileLayout.layout(template: .scorebug, enabledMetrics: all,
                                         tileRect: CGRect(x: 0, y: 0, width: 200, height: 80), hasChart: false)
        let kept = narrow.slots.map(\.metric)
        XCTAssertLessThan(kept.count, all.count)          // some fields dropped
        XCTAssertTrue(kept.contains(.bpm))                // …but never the two most important
        XCTAssertTrue(kept.contains(.zone))
        XCTAssertFalse(kept.contains(.recovery))          // the lowest-priority go first
    }

    func testScorebugAllocatesChartRegisterWhenEnabled() {
        let r = HRTileLayout.layout(template: .scorebug, enabledMetrics: [.bpm, .zone],
                                    tileRect: CGRect(x: 0, y: 0, width: 600, height: 160), hasChart: true)
        XCTAssertNotNil(r.chartRect)
        XCTAssertEqual(r.chartRect?.maxY ?? 0, 160, accuracy: 0.5)   // chart sits at the bottom
    }

    // MARK: Bento

    func testBentoHeroSpansWidthAndGridReflowsColumns() {
        let wide = HRTileLayout.layout(template: .bento, enabledMetrics: all,
                                       tileRect: CGRect(x: 0, y: 0, width: 600, height: 400), hasChart: false)
        let heroW = try! XCTUnwrap(wide.slots.first { $0.role == .hero }).frame
        XCTAssertEqual(heroW.width, 600, accuracy: 0.5)             // hero spans full width
        let wideCols = Set(fields(wide).map { ($0.frame.minX).rounded() })
        XCTAssertEqual(wideCols.count, 2)                           // 2-column grid when wide

        let narrow = HRTileLayout.layout(template: .bento, enabledMetrics: all,
                                         tileRect: CGRect(x: 0, y: 0, width: 180, height: 500), hasChart: false)
        XCTAssertEqual(try! XCTUnwrap(narrow.slots.first { $0.role == .hero }).frame.width, 180, accuracy: 0.5)
        let narrowCols = Set(fields(narrow).map { ($0.frame.minX).rounded() })
        XCTAssertEqual(narrowCols.count, 1)                        // collapses to 1 column when narrow
    }

    // MARK: List

    func testListIsSingleColumnAndTruncatesFromBottom() {
        // Short rail can't fit all 10 rows → keeps the top-priority prefix, single column.
        let r = HRTileLayout.layout(template: .list, enabledMetrics: all,
                                    tileRect: CGRect(x: 0, y: 0, width: 200, height: 120), hasChart: false)
        let xs = Set(r.slots.map { $0.frame.minX.rounded() })
        XCTAssertEqual(xs.count, 1)                                // always one column
        XCTAssertLessThan(r.slots.count, all.count)               // truncated
        // Kept = the highest-priority prefix (default order is priority order).
        XCTAssertEqual(r.slots.map(\.metric), Array(all.prefix(r.slots.count)))
        XCTAssertEqual(r.slots.first?.role, .hero)                 // first row is the lead/hero
    }

    func testListPreservesEnabledOrder() {
        let order: [HROverlayMetric] = [.maxHR, .avgHR, .hrv]
        let r = HRTileLayout.layout(template: .list, enabledMetrics: order,
                                    tileRect: CGRect(x: 0, y: 0, width: 220, height: 600), hasChart: false)
        XCTAssertEqual(r.slots.map(\.metric), order)              // order preserved, none dropped
    }

    // MARK: Ring

    func testRingHasGaugeAndCenteredHeroAtNormalSize() {
        let r = HRTileLayout.layout(template: .ring, enabledMetrics: [.bpm, .zone, .hrr],
                                    tileRect: CGRect(x: 0, y: 0, width: 300, height: 300), hasChart: false)
        XCTAssertTrue(r.slots.contains { $0.role == .gauge })
        XCTAssertTrue(r.slots.contains { $0.role == .hero && $0.metric == .bpm })
    }

    func testRingCollapsesToPillBelowMinDiameter() {
        let r = HRTileLayout.layout(template: .ring, enabledMetrics: [.bpm, .zone, .hrr],
                                    tileRect: CGRect(x: 0, y: 0, width: 50, height: 50), hasChart: false)
        XCTAssertFalse(r.slots.contains { $0.role == .gauge })    // no room for an arc
        XCTAssertTrue(r.slots.contains { $0.role == .pill })      // graceful degradation
    }

    // MARK: Cross-cutting

    func testFontNeverBelowFloorAcrossTemplatesAndSizes() {
        let rects = [CGRect(x: 0, y: 0, width: 40, height: 24),
                     CGRect(x: 0, y: 0, width: 200, height: 120),
                     CGRect(x: 0, y: 0, width: 1080, height: 300)]
        for t in HRTileTemplate.allCases {
            for rect in rects {
                for chart in [false, true] {
                    let r = HRTileLayout.layout(template: t, enabledMetrics: all, tileRect: rect, hasChart: chart)
                    for slot in r.slots {
                        XCTAssertGreaterThanOrEqual(slot.fontSize, HRTileLayout.fontFloor,
                                                    "\(t) \(rect) slot \(slot.metric) under floor")
                    }
                }
            }
        }
    }

    func testLayoutIsDeterministic() {
        let rect = CGRect(x: 0, y: 0, width: 500, height: 220)
        let a = HRTileLayout.layout(template: .scorebug, enabledMetrics: all, tileRect: rect, hasChart: true)
        let b = HRTileLayout.layout(template: .scorebug, enabledMetrics: all, tileRect: rect, hasChart: true)
        XCTAssertEqual(a, b)
    }

    func testEmptyMetricsProducesNoSlots() {
        for t in HRTileTemplate.allCases {
            let r = HRTileLayout.layout(template: t, enabledMetrics: [], tileRect: CGRect(x: 0, y: 0, width: 400, height: 200), hasChart: false)
            XCTAssertTrue(r.slots.isEmpty, "\(t) should produce no slots with no metrics")
        }
    }
}
