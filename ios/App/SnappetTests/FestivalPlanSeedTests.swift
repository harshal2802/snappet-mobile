import XCTest
@testable import Snappet

/// The festival-prompt-04 plan seed's pure builders (the UI-test fixture): the synthetic HR curve and
/// that it produces a real `.heardBefore` suggestion for the returning artist. No simulator.
final class FestivalPlanSeedTests: XCTestCase {

    func testHRCurvePeaksAroundTheClaimedIntensity() {
        let curve = FestivalPlanSeed.hrCurve()
        XCTAssertFalse(curve.isEmpty)
        let peak = curve.map(\.bpm).max() ?? 0
        XCTAssertGreaterThanOrEqual(peak, 170, "the seeded dance should read as a hard-danced set")
    }

    func testSeededHistoryDrivesAHeardBeforeSuggestionForTheReturningArtist() {
        // Reproduce the seed's past-session HR over its attendance window (120…1800 s).
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = FestivalPlanSeed.hrCurve().map { (t: $0.t, bpm: $0.bpm) }
        let window = DateInterval(start: start.addingTimeInterval(120), end: start.addingTimeInterval(1800))
        let sample = FestivalHRHistory.sample(artist: FestivalPlanSeed.historyArtist,
                                              festivalName: "Neon Nights '25", window: window,
                                              sessionStart: start, hrPoints: points)
        XCTAssertNotNil(sample)
        let history = FestivalHRHistory(samples: [sample!])

        // The now-anchored lineup the seed installs — `Overtone` is an upcoming set in it.
        let anchoredNow = Date()
        let pack = FestivalLineupSeed.pack(now: anchoredNow)
        XCTAssertTrue(pack.allSets.contains { $0.artist == FestivalPlanSeed.historyArtist },
                      "the returning artist must actually play the seeded festival")

        let out = SetRecommender.suggestions(in: pack, starred: [], history: history, now: anchoredNow)
        let overtone = out.first { $0.set.artist == FestivalPlanSeed.historyArtist }
        XCTAssertNotNil(overtone, "the artist you danced hard to should be suggested")
        if case .heardBefore = overtone?.reason {} else { XCTFail("expected a .heardBefore reason") }
    }
}
