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
        let chart = try! XCTUnwrap(r.chartRect)
        XCTAssertGreaterThan(chart.minY, 80)                       // a full-width lane in the lower half…
        XCTAssertLessThanOrEqual(chart.maxY, 160)                  // …inside the tile
        XCTAssertEqual(chart.width, r.tileRect.width * 0.92, accuracy: 1)   // ~full width (after the 0.04 inset)
    }

    // MARK: Gradient Strain (bento)

    func testGradientStrainUsesHeroLayoutWithSkin() {
        let r = HRTileLayout.layout(template: .bento, enabledMetrics: [.bpm, .zone, .hrr, .avgHR, .maxHR],
                                    tileRect: CGRect(x: 0, y: 0, width: 500, height: 360), hasChart: true)
        XCTAssertEqual(r.slots.first { $0.role == .hero }?.metric, .bpm)   // the Glass Hero layout…
        XCTAssertTrue(r.slots.contains { $0.role == .chip })               // …with value-only chips
        XCTAssertTrue(r.decorations.contains { $0.kind == .gradientSkin })  // …on an effort gradient skin
    }

    // MARK: Rail (list)

    func testRailRowsAreSingleColumnWithZoneBarAndTruncate() {
        let r = HRTileLayout.layout(template: .list, enabledMetrics: all,
                                    tileRect: CGRect(x: 0, y: 0, width: 200, height: 120), hasChart: false)
        let rows = fields(r)
        XCTAssertEqual(Set(rows.map { $0.frame.minX.rounded() }).count, 1)  // the value rows are one column
        XCTAssertLessThan(r.slots.count, all.count)                        // capped/truncated
        XCTAssertEqual(r.slots.first?.role, .hero)                         // bpm hero on top
        XCTAssertTrue(r.slots.contains { $0.role == .zoneBar })            // a vertical zone bar
    }

    func testRailPreservesRowOrder() {
        let order: [HROverlayMetric] = [.maxHR, .avgHR, .hrv]               // no zone → no bar
        let r = HRTileLayout.layout(template: .list, enabledMetrics: order,
                                    tileRect: CGRect(x: 0, y: 0, width: 220, height: 600), hasChart: false)
        XCTAssertEqual(r.slots.map(\.metric), order)              // hero + rows, order preserved, none dropped
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
            XCTAssertEqual(r.hiddenCount, 0)
        }
    }

    // MARK: Anti-crop redesign (issue #163)

    func testEveryTemplateHonorsItsVisibleCap() {
        // A generous rect + all 10 metrics: each template caps the visible count (one hero + secondary +
        // tertiary, never all 10) and parks the overflow into `hiddenCount` (→ "+N · enlarge").
        for t in HRTileTemplate.allCases {
            let r = HRTileLayout.layout(template: t, enabledMetrics: all,
                                        tileRect: CGRect(x: 0, y: 0, width: 900, height: 520), hasChart: false)
            let cap = HRTileLayout.visibleCap(t, hasChart: false)
            XCTAssertLessThanOrEqual(r.slots.count, cap, "\(t) drew \(r.slots.count) slots, cap \(cap)")
            let distinct = Set(r.slots.map(\.metric)).count
            XCTAssertLessThan(distinct, all.count, "\(t) should not draw all 10")
            // hiddenCount = enabled − covered; covered ≥ distinct (a template may also encode a metric
            // without a slot, e.g. the ring's zone as the arc colour), so it's bounded by all − distinct.
            XCTAssertGreaterThan(r.hiddenCount, 0, "\(t) should report parked metrics")
            XCTAssertLessThanOrEqual(r.hiddenCount, all.count - distinct, "\(t) hiddenCount upper bound")
        }
    }

    func testGlassHeroCardStructureAndHierarchy() {
        // The default: zone pill + giant BPM hero + sparkline + ≤3 value-only chips.
        let r = HRTileLayout.layout(template: .hero, enabledMetrics: [.bpm, .zone, .avgHR, .maxHR, .calories],
                                    tileRect: CGRect(x: 0, y: 0, width: 540, height: 360), hasChart: true)
        XCTAssertEqual(r.slots.first { $0.role == .hero }?.metric, .bpm)
        XCTAssertTrue(r.slots.contains { $0.role == .pill && $0.metric == .zone })
        let chips = r.slots.filter { $0.role == .chip }
        XCTAssertEqual(Set(chips.map(\.metric)), [.avgHR, .maxHR, .calories])
        XCTAssertNotNil(r.chartRect)                                   // sparkline carved
        // The hero owns the dominant visual weight (strictly the largest font).
        let heroFont = r.slots.first { $0.role == .hero }?.fontSize ?? 0
        XCTAssertGreaterThan(heroFont, r.slots.filter { $0.role != .hero }.map(\.fontSize).max() ?? 0)
    }

    func testHeroCardParksOverflowBehindEnlargeAffordance() {
        // Toggle every metric on: the hero card shows its 5-metric tier and parks the rest behind the
        // enlarge affordance (the catalog grew with the prompt-104 dense-data metrics).
        let r = HRTileLayout.layout(template: .hero, enabledMetrics: all,
                                    tileRect: CGRect(x: 0, y: 0, width: 540, height: 360), hasChart: true)
        XCTAssertEqual(r.slots.count, 5)
        XCTAssertEqual(r.hiddenCount, all.count - 5)
    }

    func testZoneRingDefaultSpawnHasNoFalseEnlargeHint() {
        // The ring encodes zone as the arc COLOUR (no zone slot), so its focused spawn set must report
        // hiddenCount 0 — no false "+1 · enlarge" on a pristine tile.
        let r = HRTileLayout.layout(template: .ring, enabledMetrics: HRTileTemplate.ring.spawnMetrics,
                                    tileRect: CGRect(x: 0, y: 0, width: 560, height: 340), hasChart: false)
        XCTAssertEqual(r.hiddenCount, 0)
        XCTAssertFalse(r.slots.contains { $0.metric == .zone })   // zone is not a slot…
        XCTAssertTrue(r.slots.contains { $0.role == .gauge })     // …it's the arc
    }

    func testZoneBarOrientationIsExplicitPerTemplate() {
        let broadcast = HRTileLayout.layout(template: .scorebug, enabledMetrics: [.bpm, .zone, .avgHR],
                                            tileRect: CGRect(x: 0, y: 0, width: 1000, height: 300), hasChart: false)
        XCTAssertEqual(broadcast.slots.first { $0.role == .zoneBar }?.zoneBarVertical, false)  // horizontal 5-cell
        let rail = HRTileLayout.layout(template: .list, enabledMetrics: [.bpm, .zone, .avgHR],
                                       tileRect: CGRect(x: 0, y: 0, width: 300, height: 560), hasChart: false)
        XCTAssertEqual(rail.slots.first { $0.role == .zoneBar }?.zoneBarVertical, true)        // vertical
    }

    func testChartRegisterCarvesWithinTileForHero() {
        let r = HRTileLayout.layout(template: .hero, enabledMetrics: [.bpm, .zone],
                                    tileRect: CGRect(x: 0, y: 0, width: 540, height: 360), hasChart: true)
        let chart = try? XCTUnwrap(r.chartRect)
        XCTAssertNotNil(chart)
        if let chart = chart {
            XCTAssertTrue(r.tileRect.contains(chart), "the chart register must stay inside the tile")
            XCTAssertGreaterThan(chart.height, 0)
        }
    }
}
