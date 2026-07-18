import XCTest
@testable import Snappet

/// The pure per-artist HR affinity aggregation (festival prompt 04) — re-derived from prompt 02's
/// attendance + session HR, so the recommender ranks by "how you actually danced". No simulator.
final class FestivalHRHistoryTests: XCTestCase {

    private func sample(_ artist: String, peak: Int, avg: Int, danced: TimeInterval,
                        festival: String = "Coachella '26", day: String = "2026-04-12") -> FestivalHRHistory.Sample {
        .init(artist: artist, festivalName: festival,
              date: FestivalFixtures.date("\(day)T21:00"),
              peakBPM: peak, avgBPM: avg, dancedSeconds: danced)
    }

    func testAffinityTakesMaxPeakAndWeightedAverageAcrossSessions() {
        let h = FestivalHRHistory(samples: [
            sample("Overmono", peak: 160, avg: 140, danced: 600),
            sample("Overmono", peak: 178, avg: 170, danced: 1800, festival: "Sónar '26", day: "2026-06-01"),
        ])
        let aff = h.affinity(for: "Overmono")
        XCTAssertEqual(aff?.peakBPM, 178, "peak is the best across sessions")
        XCTAssertEqual(aff?.sessionCount, 2)
        // Weighted average leans toward the longer (1800 s) session: (140·600 + 170·1800)/2400 = 162.5 → 163.
        XCTAssertEqual(aff?.avgBPM, 163)
        XCTAssertEqual(aff?.lastFestival, "Sónar '26", "most recent festival names the reason")
    }

    func testAffinityLookupIsCaseAndWhitespaceInsensitive() {
        let h = FestivalHRHistory(samples: [sample("Fred again..", peak: 171, avg: 150, danced: 3600)])
        XCTAssertNotNil(h.affinity(for: "fred  again.."))
        XCTAssertNotNil(h.affinity(for: "FRED AGAIN.."))
        XCTAssertNil(h.affinity(for: "Someone Else"))
    }

    func testOverallPriorsSummariseAllHistory() {
        let h = FestivalHRHistory(samples: [
            sample("A", peak: 150, avg: 140, danced: 1000),
            sample("B", peak: 190, avg: 165, danced: 1000),
        ])
        XCTAssertEqual(h.overallPeakBPM, 190)
        XCTAssertFalse(h.isEmpty)
    }

    func testEmptyHistoryIsEmpty() {
        XCTAssertTrue(FestivalHRHistory(samples: []).isEmpty)
        XCTAssertNil(FestivalHRHistory(samples: []).affinity(for: "Anyone"))
    }

    // MARK: - Pure slicing (the thin edge's raw material)

    func testSampleSlicesHRToTheAttendanceWindow() {
        let start = FestivalFixtures.date("2026-06-27T22:00")   // session start
        // Points every 60 s; window is 300…900 s into the session.
        let points: [(t: Double, bpm: Double)] = stride(from: 0.0, through: 1200, by: 60).map {
            ($0, $0 == 600 ? 175 : 150)   // a 175 spike at t=600, inside the window
        }
        let window = DateInterval(start: start.addingTimeInterval(300),
                                  end: start.addingTimeInterval(900))
        let s = FestivalHRHistory.sample(artist: "Overmono", festivalName: "F", window: window,
                                         sessionStart: start, hrPoints: points)
        XCTAssertEqual(s?.peakBPM, 175, "the in-window spike is the peak")
        XCTAssertEqual(s?.dancedSeconds, 600)
    }

    func testSampleIsNilWhenNoHRLandsInTheWindow() {
        let start = FestivalFixtures.date("2026-06-27T22:00")
        let points: [(t: Double, bpm: Double)] = [(0, 150), (60, 152)]
        let window = DateInterval(start: start.addingTimeInterval(600),
                                  end: start.addingTimeInterval(1200))
        XCTAssertNil(FestivalHRHistory.sample(artist: "X", festivalName: "F", window: window,
                                              sessionStart: start, hrPoints: points),
                     "a claimed set the watch wasn't on for adds no zero-diluted sample")
    }
}
