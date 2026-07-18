import XCTest
@testable import Snappet

/// The pure `SetRecommender` ranking (festival prompt 04, wireframe frame 8's "For you"). Deterministic
/// ordering + a machine-readable reason per suggestion, over the Glastonbury fixture. No simulator.
final class SetRecommenderTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()
    /// 19:00 Saturday, festival-local — before every Saturday set, so they're all upcoming candidates.
    private let now = FestivalFixtures.date("2026-06-27T19:00")

    private func setID(_ artist: String) -> UUID { FestivalFixtures.set(named: artist, in: pack).id }
    private func starred(_ artists: String...) -> Set<UUID> { Set(artists.map(setID)) }

    private func history(_ pairs: [(String, Int)]) -> FestivalHRHistory {
        FestivalHRHistory(samples: pairs.map {
            .init(artist: $0.0, festivalName: "Coachella '26",
                  date: FestivalFixtures.date("2026-04-12T21:00"),
                  peakBPM: $0.1, avgBPM: $0.1 - 20, dancedSeconds: 3600)
        })
    }

    // MARK: - Floor: fresh picks when nothing is known

    func testNoHistoryNoStarsReturnsClashFreeUpcomingFreshPicks() {
        let out = SetRecommender.suggestions(in: pack, starred: [],
                                             history: FestivalHRHistory(samples: []), now: now)
        XCTAssertEqual(out.count, 3, "the default config offers three")
        // All are freshPicks, ordered by start (Little Simz 20:00, Fred 22:15, Eric Prydz 23:00).
        XCTAssertEqual(out.map(\.set.artist), ["Little Simz", "Fred again..", "Eric Prydz"])
        XCTAssertTrue(out.allSatisfy { if case .freshPick = $0.reason { return true } else { return false } })
        XCTAssertTrue(out[0].templateReason.contains("Pyramid Stage"))
    }

    func testPastAndStarredSetsAreNeverSuggested() {
        let past = FestivalFixtures.date("2026-06-27T23:50")   // after the Saturday sets started
        let out = SetRecommender.suggestions(in: pack, starred: starred("Overmono"),
                                             history: FestivalHRHistory(samples: []), now: past)
        XCTAssertFalse(out.contains { $0.set.artist == "Overmono" }, "a star is never re-suggested")
        XCTAssertFalse(out.contains { $0.set.start <= past }, "started sets are gone")
    }

    // MARK: - Artist affinity (the top signal)

    func testHistoryArtistRanksFirstWithHeardBeforeReason() {
        let out = SetRecommender.suggestions(in: pack, starred: [],
                                             history: history([("Overmono", 171)]), now: now)
        XCTAssertEqual(out.first?.set.artist, "Overmono", "an artist you danced hard to leads")
        guard case let .heardBefore(artist, peak, festival) = out.first?.reason else {
            return XCTFail("expected .heardBefore")
        }
        XCTAssertEqual(artist, "Overmono")
        XCTAssertEqual(peak, 171)
        XCTAssertEqual(festival, "Coachella '26")
        XCTAssertTrue(out.first!.templateReason.contains("171"))
        XCTAssertTrue(out.first!.templateReason.contains("Coachella '26"))
    }

    func testStrongerPeakOutranksWeakerPeak() {
        let out = SetRecommender.suggestions(in: pack, starred: [],
                                             history: history([("Overmono", 150), ("Fred again..", 185)]),
                                             now: now)
        // Both are matches; the harder-danced one (Fred, 185) ranks above Overmono (150).
        let fredIdx = out.firstIndex { $0.set.artist == "Fred again.." }
        let overIdx = out.firstIndex { $0.set.artist == "Overmono" }
        XCTAssertNotNil(fredIdx); XCTAssertNotNil(overIdx)
        XCTAssertLessThan(fredIdx!, overIdx!)
    }

    // MARK: - Gaps + walk

    func testCandidateInsideAPlanGapGetsFillsGapReason() {
        // Star Little Simz (20:00–21:15) + Jayda G (01:00–02:30) → gap 21:15…01:00.
        let out = SetRecommender.suggestions(in: pack, starred: starred("Little Simz", "Jayda G"),
                                             history: FestivalHRHistory(samples: []), now: now)
        let fred = out.first { $0.set.artist == "Fred again.." }
        XCTAssertNotNil(fred, "a set inside the gap should be offered")
        guard case let .fillsGap(gapStart, _) = fred?.reason else { return XCTFail("expected .fillsGap") }
        XCTAssertEqual(gapStart, FestivalFixtures.date("2026-06-27T21:15"))
        XCTAssertTrue(fred!.templateReason.contains("Fills the empty"))
    }

    func testSameStageStarGivesSameStageReasonAndBonus() {
        // Only one star → no gap (needs ≥2). Fred shares Pyramid with Little Simz.
        let out = SetRecommender.suggestions(in: pack, starred: starred("Little Simz"),
                                             history: FestivalHRHistory(samples: []), now: now)
        let fred = out.first { $0.set.artist == "Fred again.." }
        guard case let .sameStage(star) = fred?.reason else { return XCTFail("expected .sameStage") }
        XCTAssertEqual(star, "Little Simz")
        // Scores above a plain fresh pick on another stage.
        let eric = out.first { $0.set.artist == "Eric Prydz" }
        XCTAssertGreaterThan(fred!.score, eric?.score ?? 0)
    }

    // MARK: - Clash avoidance (hard drop)

    func testASetClashingWithAStarIsNeverSuggested() {
        // Overmono 23:30–01:00 overlaps Eric Prydz 23:00–00:30.
        let out = SetRecommender.suggestions(in: pack, starred: starred("Overmono"),
                                             history: history([("Eric Prydz", 190)]), now: now)
        XCTAssertFalse(out.contains { $0.set.artist == "Eric Prydz" },
                       "even a strong-affinity set is dropped when it clashes your plan")
    }

    // MARK: - Determinism + limit

    func testRankingIsDeterministic() {
        let h = history([("Fred again..", 175)])
        let a = SetRecommender.suggestions(in: pack, starred: starred("Little Simz"), history: h, now: now)
        let b = SetRecommender.suggestions(in: pack, starred: starred("Little Simz"), history: h, now: now)
        XCTAssertEqual(a, b)
    }

    func testLimitIsRespected() {
        var config = SetRecommender.Config.default
        config.limit = 2
        let out = SetRecommender.suggestions(in: pack, starred: [],
                                             history: FestivalHRHistory(samples: []), now: now,
                                             config: config)
        XCTAssertEqual(out.count, 2)
    }
}
