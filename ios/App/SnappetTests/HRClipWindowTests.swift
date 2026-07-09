import XCTest
@testable import Snappet

/// Unit tests for the **extended HR window** (prompt 115) — the pure model + placement + playhead
/// mapping that let a clip's chart show HR beyond the footage (lead-in before `clip_start`, tail after
/// `clip_end`, where a hard move's peak lands) while the live dot sweeps only the on-camera span.
final class HRClipWindowTests: XCTestCase {

    // MARK: - HRClipWindow fraction math

    /// An unextended window is the identity: no panes, video fraction == chart fraction.
    func testFootageOnlyWindowIsIdentity() {
        let w = HRClipWindow.footageOnly(30)
        XCTAssertFalse(w.isExtended)
        XCTAssertEqual(w.spanSec, 30)
        XCTAssertEqual(w.footageStartFraction(maxT: 30), 0)
        XCTAssertEqual(w.footageEndFraction(maxT: 30), 1)
        XCTAssertEqual(w.chartFraction(videoFraction: 0.5, maxT: 30), 0.5, accuracy: 1e-9)
    }

    /// lead 5 + footage 30 + tail 25 = span 60: the footage occupies [5/60, 35/60] of a full-coverage
    /// chart, and video progress maps linearly onto exactly that sub-range.
    func testExtendedWindowFractions() {
        let w = HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 25)
        XCTAssertTrue(w.isExtended)
        XCTAssertEqual(w.spanSec, 60)
        XCTAssertEqual(w.footageStartFraction(maxT: 60), 5.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(w.footageEndFraction(maxT: 60), 35.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(w.chartFraction(videoFraction: 0, maxT: 60), 5.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(w.chartFraction(videoFraction: 1, maxT: 60), 35.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(w.chartFraction(videoFraction: 0.5, maxT: 60), 20.0 / 60, accuracy: 1e-9)
    }

    /// When HR coverage ends inside the tail (the slicer holds its endpoint at the data edge, so the
    /// chart's `maxT` < the nominal span), all fractions grow against the SAME shorter denominator —
    /// the dot, panes, and curve stay on one x-axis, and nothing exceeds 1.
    func testCoverageClampedTailKeepsFractionsConsistent() {
        let w = HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 30)   // nominal span 65
        let maxT = 45.0                                                  // data ends 10 s into the tail
        XCTAssertEqual(w.footageStartFraction(maxT: maxT), 5.0 / 45, accuracy: 1e-9)
        XCTAssertEqual(w.footageEndFraction(maxT: maxT), 35.0 / 45, accuracy: 1e-9)
        XCTAssertEqual(w.chartFraction(videoFraction: 1, maxT: maxT), 35.0 / 45, accuracy: 1e-9)
        // Degenerate: data ends before the footage does → end fraction clamps to 1.
        XCTAssertEqual(w.footageEndFraction(maxT: 20), 1)
        XCTAssertEqual(w.chartFraction(videoFraction: 1, maxT: 20), 1)
    }

    // MARK: - StudioHRPlacement.extendedWindow

    /// The window start moves back by the lead and the slicer span covers lead + footage + tail.
    func testExtendedWindowWidensTheCaptureWindow() {
        let ext = StudioHRPlacement.extendedWindow(offset: 100, trimStart: 10, trimEnd: 40,
                                                   sourceDuration: 60, leadSec: 5, tailSec: 30)
        XCTAssertEqual(ext.start, 105)                       // (100 + 10) − 5
        XCTAssertEqual(ext.window.leadSec, 5)
        XCTAssertEqual(ext.window.footageSec, 30)            // trims 10…40
        XCTAssertEqual(ext.window.tailSec, 30)
        XCTAssertEqual(ext.window.spanSec, 65)
    }

    /// A clip filmed right at session start can't lead past t=0: the EFFECTIVE lead clamps to what
    /// exists, so the region math stays aligned with what actually got sliced.
    func testLeadClampsAtSessionStart() {
        let ext = StudioHRPlacement.extendedWindow(offset: 2, trimStart: 0, trimEnd: 20,
                                                   sourceDuration: 20, leadSec: 5, tailSec: 0)
        XCTAssertEqual(ext.start, 0)
        XCTAssertEqual(ext.window.leadSec, 2)                // only 2 s of session before the clip
    }

    /// `sampleExtended` slices the widened window per clip (reads the clip's stored lead/tail) and the
    /// legacy `sample` stays footage-only — existing callers see no behaviour change.
    func testSampleExtendedSlicesWiderThanLegacySample() {
        let series = stride(from: 0.0, through: 600.0, by: 1.0).map { HRPoint(t: $0, bpm: $0) } // bpm==t
        var c = TimelineClip(sessionMediaID: UUID(), localIdentifier: "a", isPhoto: false,
                             order: 0, trimStart: 0, trimEnd: 30)
        c.hrLeadSec = 5; c.hrTailSec = 30
        let offsets = [c.id: 100.0], durations = [c.id: 30.0]

        let ext = StudioHRPlacement.sampleExtended(clips: [c], offsets: offsets,
                                                   sourceDurations: durations, series: series)[c.id]
        let legacy = StudioHRPlacement.sample(clips: [c], offsets: offsets,
                                              sourceDurations: durations, series: series)[c.id]
        XCTAssertNotNil(ext); XCTAssertNotNil(legacy)
        // Extended: window-local [0, 65] covering session [95, 160]; legacy: [0, 30] over [100, 130].
        XCTAssertEqual(ext!.samples.last!.t, 65, accuracy: 0.01)
        XCTAssertEqual(ext!.samples.first!.bpm, 95, accuracy: 0.01)
        XCTAssertEqual(ext!.samples.last!.bpm, 160, accuracy: 0.01)
        XCTAssertEqual(legacy!.last!.t, 30, accuracy: 0.01)
        XCTAssertEqual(legacy!.last!.bpm, 130, accuracy: 0.01)
        XCTAssertEqual(ext!.window, HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 30))
    }

    // MARK: - Offset recovery (the whole-session-burn bug)

    /// A clip whose `sessionMediaID` link is lost still resolves its capture offset via the
    /// denormalized `localIdentifier` — so per-clip slicing (and lead/tail) keep working instead of
    /// falling through to the session-wide burn.
    func testResolveOffsetsFallsBackToLocalIdentifier() {
        let linked = TimelineClip(sessionMediaID: UUID(), localIdentifier: "A", isPhoto: false, order: 0)
        let unlinked = TimelineClip(sessionMediaID: nil, localIdentifier: "B", isPhoto: false, order: 1)
        let stale = TimelineClip(sessionMediaID: UUID(), localIdentifier: "C", isPhoto: false, order: 2)
        let unknown = TimelineClip(sessionMediaID: nil, localIdentifier: "nope", isPhoto: false, order: 3)
        let byMediaID = [linked.sessionMediaID!: 10.0]
        let byLocalID = ["B": 20.0, "C": 30.0]
        let out = StudioHRPlacement.resolveOffsets(clips: [linked, unlinked, stale, unknown],
                                                   byMediaID: byMediaID, byLocalID: byLocalID)
        XCTAssertEqual(out[linked.id], 10)     // primary: the media-id link
        XCTAssertEqual(out[unlinked.id], 20)   // fallback: localIdentifier
        XCTAssertEqual(out[stale.id], 30)      // stale media id → healed by localIdentifier
        XCTAssertNil(out[unknown.id])          // resolvable by neither → honestly absent
    }

    // MARK: - TimelineClip persistence (migration safety + defaults)

    /// A pre-115 persisted clip (no HR-window keys) decodes with `nil` stored values, which read as
    /// the defaults — and explicit values round-trip.
    func testTimelineClipDecodesLegacyBlobAndRoundTrips() throws {
        var c = TimelineClip(sessionMediaID: nil, localIdentifier: "x", isPhoto: false, order: 0)
        // Simulate a legacy blob: encode, strip the new keys, decode.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        json.removeValue(forKey: "hrLeadSec")
        json.removeValue(forKey: "hrTailSec")
        json.removeValue(forKey: "hrMetricsScopeRaw")
        let legacy = try JSONDecoder().decode(TimelineClip.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.hrLeadSec)
        XCTAssertEqual(legacy.hrWindowLeadSec, HRClipWindow.defaultLeadSec)
        XCTAssertEqual(legacy.hrWindowTailSec, HRClipWindow.defaultTailSec)
        XCTAssertEqual(legacy.hrMetricsScope, .window)

        c.hrLeadSec = 0; c.hrTailSec = 45; c.hrMetricsScope = .clip
        let round = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(round.hrWindowLeadSec, 0)
        XCTAssertEqual(round.hrWindowTailSec, 45)
        XCTAssertEqual(round.hrMetricsScope, .clip)
    }

    /// The pure editor mutator stores clamped values and `nil` resets to "track the default".
    func testSetClipHRWindowClampsAndResets() {
        let c = TimelineClip(sessionMediaID: nil, localIdentifier: "x", isPhoto: false, order: 0)
        var s = StudioProjectSnapshot(title: "T", aspectRaw: "portrait9x16", backgroundRaw: "black",
                                      clips: [c], transitions: [], overlays: [], audioTracks: [])
        s = StudioProjectEditor.setClipHRWindow(s, id: c.id, leadSec: 99, tailSec: 500, scope: .clip)
        XCTAssertEqual(s.clips[0].hrLeadSec, HRClipWindow.maxLeadSec)
        XCTAssertEqual(s.clips[0].hrTailSec, HRClipWindow.maxTailSec)
        XCTAssertEqual(s.clips[0].hrMetricsScope, .clip)
        s = StudioProjectEditor.setClipHRWindow(s, id: c.id, leadSec: nil, tailSec: nil, scope: nil)
        XCTAssertNil(s.clips[0].hrLeadSec)
        XCTAssertNil(s.clips[0].hrTailSec)
        XCTAssertNil(s.clips[0].hrMetricsScopeRaw)
    }

    // MARK: - Region pane geometry (the ONE Variant-A geometry both renderers consume)

    /// Panes: zero-width segments drop; a normal window yields lead/footage/tail in order.
    func testRegionPanesDropZeroWidthSegments() {
        let normal = HRWindowRegionStyle.panes(footageStart: 0.1, footageEnd: 0.6)
        XCTAssertEqual(normal.count, 3)
        XCTAssertEqual(normal.map(\.hex), [HRWindowRegionStyle.leadHex,
                                           HRWindowRegionStyle.footageHex,
                                           HRWindowRegionStyle.tailHex])
        // No lead (fs = 0) → the lead pane drops; footage reaching the edge (fe = 1) → tail drops.
        XCTAssertEqual(HRWindowRegionStyle.panes(footageStart: 0, footageEnd: 1).count, 1)
        // Degenerate footage (fs == fe) → the footage pane itself drops, no zero-width artifacts.
        let degenerate = HRWindowRegionStyle.panes(footageStart: 1, footageEnd: 1)
        XCTAssertEqual(degenerate.map(\.hex), [HRWindowRegionStyle.leadHex])
    }

    /// Ticks: edge-adjacent xs drop, and a degenerate window (fs == fe) yields ONE tick — never two
    /// coincident values (which would collide as SwiftUI ForEach identities).
    func testRegionTickXsDropEdgesAndDedupe() {
        XCTAssertEqual(HRWindowRegionStyle.tickXs(footageStart: 0.1, footageEnd: 0.6), [0.1, 0.6])
        XCTAssertEqual(HRWindowRegionStyle.tickXs(footageStart: 0, footageEnd: 0.6), [0.6])
        XCTAssertEqual(HRWindowRegionStyle.tickXs(footageStart: 0.1, footageEnd: 1), [0.1])
        XCTAssertEqual(HRWindowRegionStyle.tickXs(footageStart: 0.5, footageEnd: 0.5), [0.5])
        XCTAssertTrue(HRWindowRegionStyle.tickXs(footageStart: 1, footageEnd: 1).isEmpty)
    }

    // MARK: - Playhead keyframes (the export dot)

    /// Without a window the keyframes are the pre-115 behaviour: one per chart point, keyTime = x.
    func testPlayheadKeyframesIdentityWithoutWindow() {
        let chart = stride(from: 0.0, through: 30.0, by: 1.0).map { HRPoint(t: $0, bpm: 100 + $0) }
        let keys = HRChartGeometry.playheadKeyframes(chart, window: nil)
        XCTAssertEqual(keys.count, chart.count)
        for k in keys { XCTAssertEqual(k.keyTime, k.x, accuracy: 1e-9) }
        XCTAssertEqual(keys.first!.keyTime, 0, accuracy: 1e-9)
        XCTAssertEqual(keys.last!.keyTime, 1, accuracy: 1e-9)
    }

    /// With an extended window the dot ENTERS at the lead/footage boundary (keyTime 0), sweeps only
    /// the footage span, and PARKS at the footage/tail boundary (keyTime 1) — the tail is drawn but
    /// never swept, and the boundary bpm values are interpolated correctly.
    func testPlayheadKeyframesConfinedToFootage() {
        // Window-local chart over [0, 60]: bpm == 100 + t (easy to assert interpolated values).
        let chart = stride(from: 0.0, through: 60.0, by: 1.0).map { HRPoint(t: $0, bpm: 100 + $0) }
        let w = HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 25)
        let keys = HRChartGeometry.playheadKeyframes(chart, window: w)
        XCTAssertEqual(keys.first!.keyTime, 0)
        XCTAssertEqual(keys.last!.keyTime, 1)
        // Boundary positions: x at the footage edges, bpm interpolated at t=5 and t=35.
        XCTAssertEqual(keys.first!.x, 5.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(keys.first!.bpm, 105, accuracy: 0.01)
        XCTAssertEqual(keys.last!.x, 35.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(keys.last!.bpm, 135, accuracy: 0.01)
        // Every keyframe stays inside the footage sub-range and keyTimes are strictly increasing.
        for k in keys {
            XCTAssertGreaterThanOrEqual(k.x, 5.0 / 60 - 1e-9)
            XCTAssertLessThanOrEqual(k.x, 35.0 / 60 + 1e-9)
        }
        for (a, b) in zip(keys, keys.dropFirst()) { XCTAssertLessThan(a.keyTime, b.keyTime) }
        // Mid-footage: keyTime 0.5 ↔ window t = 20 ↔ x = 20/60.
        let mid = keys.min { abs($0.keyTime - 0.5) < abs($1.keyTime - 0.5) }!
        XCTAssertEqual(mid.x, 20.0 / 60, accuracy: 0.02)
    }

    /// Data ends before the footage starts (everything clamps): the dot parks at the boundary for the
    /// whole slot instead of sweeping a nonexistent span.
    func testPlayheadKeyframesParkOnDegenerateFootageSpan() {
        let chart = [HRPoint(t: 0, bpm: 120), HRPoint(t: 4, bpm: 130)]   // data ends inside the lead
        let w = HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 0)
        let keys = HRChartGeometry.playheadKeyframes(chart, window: w)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].x, keys[1].x, accuracy: 1e-9)
        XCTAssertEqual(keys[0].keyTime, 0)
        XCTAssertEqual(keys[1].keyTime, 1)
    }

    // MARK: - HROverlayValues: scope + fraction remap

    private func windowValues(scope: HRMetricsScope) -> HROverlayValues {
        // Window-local [0, 65]: lead [0,5], footage [5,35], tail [35,65]. The bpm PEAKS in the tail
        // (t=44 → 180) — the user's whole use-case.
        let samples = stride(from: 0.0, through: 65.0, by: 1.0).map { t in
            HRPoint(t: t, bpm: t <= 35 ? 100 + t : (t <= 44 ? 135 + (t - 35) * 5 : 180 - (t - 44) * 2))
        }
        let w = HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 30)
        let footage = HRWindowSlicer.slice(samples, start: w.leadSec, span: w.footageSec)
        return HROverlayValues(samples: samples, durationSec: 65, maxHR: 190, restHR: 60,
                               window: w,
                               statsSamples: scope == .clip ? footage : nil,
                               statsDurationSec: scope == .clip ? 30 : nil)
    }

    /// Full-window scope: PEAK includes the off-camera tail spike. Clip scope: footage-only numbers.
    func testMetricsScopeChangesAggregates() {
        let windowScoped = windowValues(scope: .window)
        let clipScoped = windowValues(scope: .clip)
        XCTAssertEqual(windowScoped.staticValue(.maxHR, fallbackHex: "#FFFFFF")!.value, "180")
        XCTAssertEqual(clipScoped.staticValue(.maxHR, fallbackHex: "#FFFFFF")!.value, "135")
    }

    /// The one video→chart remap: video 0 lands at the lead boundary, video 1 at the footage/tail
    /// boundary — and a LIVE reading at video-end shows the last ON-CAMERA bpm, not the tail peak.
    func testChartFractionAndLiveReadingTrackFootage() {
        let v = windowValues(scope: .window)
        XCTAssertEqual(v.chartFraction(forVideoFraction: 0), 5.0 / 65, accuracy: 1e-9)
        XCTAssertEqual(v.chartFraction(forVideoFraction: 1), 35.0 / 65, accuracy: 1e-9)
        var el = HROverlayElement(metric: .bpm, colorHex: "#FFFFFF")
        el.live = true
        let atEnd = v.reading(for: el, atFraction: v.chartFraction(forVideoFraction: 1))!
        XCTAssertEqual(Double(atEnd.value)!, 135, accuracy: 3)   // footage-end bpm, NOT the 180 peak
    }

    /// Animated segments stay in VIDEO-fraction domain (for slot gating) while their readings resolve
    /// at the mapped chart fractions: the first segment reads the lead-boundary bpm, the last reads
    /// the footage-end bpm.
    func testAnimatedSegmentsResolveOverFootageSpan() {
        let v = windowValues(scope: .window)
        var el = HROverlayElement(metric: .bpm, colorHex: "#FFFFFF")
        el.live = true; el.animated = true
        let segs = v.segments(for: el)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertEqual(segs.first!.start, 0)
        XCTAssertEqual(segs.last!.end, 1)
        XCTAssertEqual(Double(segs.first!.reading.value)!, 105, accuracy: 3)   // bpm at window t=5
        XCTAssertEqual(Double(segs.last!.reading.value)!, 135, accuracy: 3)    // bpm at window t=35
    }

    /// `resolveTile` carries the window through to the export (`ResolvedHRTile.window`), and a
    /// windowless build stays `nil` (feed / reel exporter untouched).
    func testResolveTileCarriesWindow() {
        let v = windowValues(scope: .window)
        let tile = HRTile.make(template: .scorebug)
        XCTAssertEqual(v.resolveTile(tile)?.window, HRClipWindow(leadSec: 5, footageSec: 30, tailSec: 30))
        let plain = HROverlayValues(samples: [HRPoint(t: 0, bpm: 100), HRPoint(t: 30, bpm: 140)],
                                    durationSec: 30, maxHR: 190, restHR: 60)
        XCTAssertNil(plain.resolveTile(tile)?.window)
    }
}
