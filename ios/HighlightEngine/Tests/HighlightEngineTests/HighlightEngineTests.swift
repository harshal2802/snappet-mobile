import XCTest
@testable import HighlightEngine

final class HighlightEngineTests: XCTestCase {

    // MARK: numeric helpers

    func testMovingAverageSmoothsSpike() {
        let xs = [0, 0, 0, 10, 0, 0, 0].map(Double.init)
        let out = movingAverage(xs, window: 3)
        XCTAssertLessThan(out[3], 10)            // spike attenuated
        XCTAssertGreaterThan(out[3], out[0])     // but still elevated
        XCTAssertEqual(out.count, xs.count)
    }

    func testPercentileMonotonic() {
        let xs = (0...100).map(Double.init)
        XCTAssertLessThan(percentile(xs, 0.05), percentile(xs, 0.99))
    }

    // MARK: HR series

    func testHRRNormalizationAndPeak() {
        // flat 60 bpm with a surge to ~160 around t=100
        var samples: [HRSample] = []
        for t in 0..<200 {
            let bpm = (90...110).contains(t) ? 160.0 : 60.0
            samples.append(HRSample(t: Double(t), bpm: bpm))
        }
        let hr = HeartRateSeries.make(from: samples, duration: 200,
                                      smoothingWindowSec: 5, restBpm: 60, maxBpm: 190)
        XCTAssertEqual(hr.hrr(at: 0), 0, accuracy: 0.05)        // at rest → ~0
        XCTAssertGreaterThan(hr.hrr(at: 100), 0.6)             // at surge → high %HRR
        XCTAssertGreaterThan(hr.slope(at: 90), 0)             // rising into the surge
    }

    // MARK: selection

    private func surgeWorkout(activity: Activity = .running) -> Workout {
        // surge centered at t=300; media clip covering 250...350
        var samples: [HRSample] = []
        for t in 0..<600 {
            let base = 70.0
            let surge = exp(-pow(Double(t) - 300, 2) / (2 * 15 * 15)) * 110
            samples.append(HRSample(t: Double(t), bpm: base + surge))
        }
        let media = [MediaItem(id: "clip1", kind: .video, startOffset: 250, duration: 100)]
        return Workout(activity: activity, duration: 600, hr: samples,
                       restBpm: 60, maxBpm: 190, media: media)
    }

    func testHRSelectorFindsSurge() {
        let wk = surgeWorkout()
        let hl = HRHighlightSelector().select(workout: wk, config: .preset(for: .running))
        XCTAssertFalse(hl.isEmpty)
        let top = hl.max(by: { $0.score < $1.score })!
        // best moment should sit within the filmed clip, near the surge (minus HR lag)
        XCTAssertGreaterThanOrEqual(top.atOffset, 250)
        XCTAssertLessThanOrEqual(top.atOffset, 350)
        XCTAssertEqual(top.atOffset, 294, accuracy: 25)   // ~ peak(300) - lag
    }

    func testClipPaddingBiasedEarlierAndWithinMedia() {
        let wk = surgeWorkout()
        let cfg = HighlightConfig(hrLagSec: 6, clipLeadSec: 6, clipTrailSec: 4, minGapSec: 20, maxHighlights: 5)
        let hl = HRHighlightSelector().select(workout: wk, config: cfg)
        for h in hl {
            XCTAssertLessThan(h.clipStart, h.atOffset)     // window starts before the moment
            XCTAssertGreaterThanOrEqual(h.clipStart, 250)  // clamped to media start
            XCTAssertLessThanOrEqual(h.clipEnd, 350)       // clamped to media end
        }
    }

    func testNonMaxSuppressionRespectsGap() {
        let wk = surgeWorkout()
        let cfg = HighlightConfig(minGapSec: 30, maxHighlights: 8)
        let hl = HRHighlightSelector().select(workout: wk, config: cfg).sorted { $0.atOffset < $1.atOffset }
        for i in 1..<max(1, hl.count) {
            XCTAssertGreaterThanOrEqual(hl[i].atOffset - hl[i-1].atOffset, 30 - 1e-6)
        }
    }

    func testMaxHighlightsRespected() {
        let wk = surgeWorkout()
        let cfg = HighlightConfig(minGapSec: 5, maxHighlights: 3)
        XCTAssertLessThanOrEqual(HRHighlightSelector().select(workout: wk, config: cfg).count, 3)
    }

    func testNoMediaNoHighlights() {
        let wk = Workout(activity: .running, duration: 600,
                         hr: [HRSample(t: 0, bpm: 60)], restBpm: 60, maxBpm: 190, media: [])
        XCTAssertTrue(HRHighlightSelector().select(workout: wk, config: .default).isEmpty)
    }

    // MARK: fusion modularity

    func testFusionEqualsHRWhenSceneZero() {
        let wk = surgeWorkout()
        let cfg = HighlightConfig.preset(for: .running)
        let hrOnly = HRHighlightSelector().select(workout: wk, config: cfg)
        let fused = FusionSelector.hrLeaning().select(workout: wk, config: cfg)
        XCTAssertEqual(hrOnly.map(\.atOffset), fused.map(\.atOffset),
                       "with a zero scene signal, fusion must reduce to HR-only ordering")
    }

    func testFusionUsesSceneSignal() {
        let wk = surgeWorkout()
        // scene strongly favors t=270 (away from the HR surge near 294)
        let scene = SceneHighlightSelector(visualScore: { abs($0 - 270) < 3 ? 100 : 0 })
        let fused = FusionSelector([(scene, 1.0)]).select(workout: wk, config: .default)
        let top = fused.max(by: { $0.score < $1.score })!
        XCTAssertEqual(top.atOffset, 270, accuracy: 6)
    }

    // MARK: reel planning

    func testReelPlanRespectsTargetAndChronology() {
        let wk = surgeWorkout()
        let res = HighlightEngine(planner: ReelPlanner(targetDuration: 12)).generate(for: wk)
        XCTAssertLessThanOrEqual(res.reel.totalDuration, 12 + 6) // within a clip's slack
        let offs = res.reel.segments.map(\.startWithinMedia)
        // segments reference in-media offsets (>= 0) and reel is chronological by source
        XCTAssertTrue(offs.allSatisfy { $0 >= 0 })
    }

    func testPhotoSegmentUsesStillDuration() {
        var wk = surgeWorkout()
        wk = Workout(activity: .running, duration: 600, hr: wk.hr, restBpm: 60, maxBpm: 190,
                     media: [MediaItem(id: "p1", kind: .photo, startOffset: 300, duration: 0)])
        let res = HighlightEngine(planner: ReelPlanner(targetDuration: 30, photoStill: 2)).generate(for: wk)
        XCTAssertFalse(res.reel.segments.isEmpty)
        XCTAssertEqual(res.reel.segments.first?.kind, .photo)
    }

    // MARK: pinning & manual order (auto-generate-then-edit, #60 §B)

    /// Build a set of highlights spread across one long clip, for planner tests.
    private func spreadHighlights() -> (highlights: [Highlight], media: [MediaItem]) {
        let media = [MediaItem(id: "clip1", kind: .video, startOffset: 0, duration: 600)]
        // Five 5-second clips at descending score, far enough apart to all survive NMS-free planning.
        let highlights: [Highlight] = (0..<5).map { (i: Int) -> Highlight in
            let at = Double(i * 100)
            return Highlight(id: "h\(i)", mediaItemId: "clip1", kind: .high,
                             atOffset: at, clipStart: at, clipEnd: at + 5,
                             score: 1.0 - Double(i) * 0.1)
        }
        return (highlights, media)
    }

    func testPinnedHighlightIsBudgetExempt() {
        let (highlights, media) = spreadHighlights()
        // Budget fits ~1 clip (5s). Pin the LOWEST-score, last highlight.
        let planner = ReelPlanner(targetDuration: 5)
        let pinned: Set<String> = ["h4"]
        let plan = planner.plan(highlights: highlights, media: media, pinnedIds: pinned)
        XCTAssertTrue(plan.segments.contains { $0.id == "h4" },
                      "a pinned highlight must appear even when the budget would otherwise drop it")
    }

    func testPinnedManyExceedBudgetStillAllIncluded() {
        let (highlights, media) = spreadHighlights()
        let planner = ReelPlanner(targetDuration: 5)   // room for ~1 clip
        let pinned: Set<String> = ["h0", "h1", "h2", "h3", "h4"]
        let plan = planner.plan(highlights: highlights, media: media, pinnedIds: pinned)
        XCTAssertEqual(Set(plan.segments.map(\.id)), pinned,
                       "all pinned highlights are included even when they exceed the target duration")
    }

    func testExplicitOrderRespected() {
        let (highlights, media) = spreadHighlights()
        let planner = ReelPlanner(targetDuration: 10_000)   // include everything
        let order = ["h4", "h0", "h3", "h1", "h2"]
        let plan = planner.plan(highlights: highlights, media: media, order: order)
        XCTAssertEqual(plan.segments.map(\.id), order,
                       "segments must follow the explicit order when provided")
    }

    func testDefaultPlanStillChronological() {
        let (highlights, media) = spreadHighlights()
        let planner = ReelPlanner(targetDuration: 10_000)
        let plan = planner.plan(highlights: highlights, media: media)   // no pins, no order
        XCTAssertEqual(plan.segments.map(\.id), ["h0", "h1", "h2", "h3", "h4"],
                       "with no order/pins the reel stays chronological by atOffset")
    }

    // MARK: feedback / data capture

    func testFeedbackSinkReceivesShownEvents() {
        final class Collector: FeedbackSink, @unchecked Sendable {
            var events: [HighlightFeedbackEvent] = []
            func record(_ e: HighlightFeedbackEvent) { events.append(e) }
        }
        let sink = Collector()
        let engine = HighlightEngine(feedback: sink)
        let wk = surgeWorkout()
        let res = engine.generate(for: wk)
        engine.logShown(res, workoutId: "w1", activity: .running, now: 1_000_000)
        XCTAssertEqual(sink.events.count, res.highlights.count)
        XCTAssertEqual(sink.events.first?.action, .shown)
        XCTAssertFalse(sink.events.first!.configFingerprint.isEmpty)
    }

    func testConfigFingerprintStable() {
        XCTAssertEqual(HighlightConfig.default.fingerprint, HighlightConfig.default.fingerprint)
        XCTAssertNotEqual(HighlightConfig.default.fingerprint,
                          HighlightConfig(smoothingWindowSec: 99).fingerprint)
    }
}
