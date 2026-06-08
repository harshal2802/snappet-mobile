import XCTest
@testable import HighlightEngine

final class HRVMetricsTests: XCTestCase {

    func testKnownArrayMatchesHandComputed() {
        // RR (ms): successive diffs = [+50, -30, +40, -10]. RMSSD = sqrt((2500+900+1600+100)/4) = sqrt(1275).
        let rr = [800.0, 850, 820, 860, 850]
        let m = HRVMetrics.make(rrIntervalsMs: rr, minIntervals: 5)
        XCTAssertEqual(try XCTUnwrap(m.rmssd), (1275.0).squareRoot(), accuracy: 0.001)
        // SDNN = population stddev of the five values (mean 836).
        let mean = 836.0
        let varr = rr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 5
        XCTAssertEqual(try XCTUnwrap(m.sdnn), varr.squareRoot(), accuracy: 0.001)
        // pNN50: only the first diff (+50) is NOT > 50; none exceed 50 except... |+50|>50 is false.
        // diffs |50|,|30|,|40|,|10| → zero exceed 50 → pNN50 = 0.
        XCTAssertEqual(try XCTUnwrap(m.pnn50), 0, accuracy: 0.001)
        XCTAssertEqual(m.beatCount, 5)
    }

    func testPNN50CountsBigSwings() {
        // diffs: +100, -100, +100, -100 → all exceed 50 → pNN50 = 1.0
        let m = HRVMetrics.make(rrIntervalsMs: [800, 900, 800, 900, 800], minIntervals: 5)
        XCTAssertEqual(try XCTUnwrap(m.pnn50), 1.0, accuracy: 0.001)
    }

    func testBelowMinimumIsEmpty() {
        XCTAssertEqual(HRVMetrics.make(rrIntervalsMs: [800, 820, 810], minIntervals: 5), .empty)
        XCTAssertEqual(HRVMetrics.make(rrIntervalsMs: [], minIntervals: 5), .empty)
    }

    func testFiltersImplausibleRR() {
        // A 100 ms (600 bpm) artifact and a 5000 ms gap are dropped; the 5 plausible beats remain.
        let m = HRVMetrics.make(rrIntervalsMs: [100, 800, 820, 810, 805, 815, 5000], minIntervals: 5)
        XCTAssertEqual(m.beatCount, 5)
        XCTAssertNotNil(m.rmssd)
    }

    func testWindowGathersFromSamples() {
        let samples = [
            HRSample(t: 0, bpm: 120, rrIntervalsMs: [800, 810]),
            HRSample(t: 10, bpm: 118, rrIntervalsMs: [820, 815, 805]),
            HRSample(t: 99, bpm: 150, rrIntervalsMs: [500, 510]),   // outside the window
        ]
        let m = HRVMetrics.make(from: samples, start: 0, end: 30, minIntervals: 5)
        XCTAssertEqual(m.beatCount, 5)   // 2 + 3 from the in-window samples, not the t=99 one
        XCTAssertNotNil(m.rmssd)
    }

    func testWindowEmptyWithoutRR() {
        let samples = [HRSample(t: 0, bpm: 120), HRSample(t: 5, bpm: 122)]   // no RR (untrusted/watch)
        XCTAssertEqual(HRVMetrics.make(from: samples, start: 0, end: 30), .empty)
    }
}
