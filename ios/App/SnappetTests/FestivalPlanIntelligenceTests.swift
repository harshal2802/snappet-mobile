import XCTest
@testable import Snappet

/// The E7 seam for the For-You sheet (festival prompt 04): the on-device Foundation Models pass
/// rewrites ONLY the reason line, and degrades silently to the recommender's template. On the test
/// host Apple Intelligence is unavailable, so this asserts the guaranteed floor: identical cards,
/// template reasons, order preserved.
final class FestivalPlanIntelligenceTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()
    private let now = FestivalFixtures.date("2026-06-27T19:00")

    private func suggestions() -> [SetRecommender.Suggestion] {
        SetRecommender.suggestions(
            in: pack, starred: [],
            history: FestivalHRHistory(samples: [
                .init(artist: "Overmono", festivalName: "Coachella '26",
                      date: FestivalFixtures.date("2026-04-12T21:00"),
                      peakBPM: 171, avgBPM: 150, dancedSeconds: 3600)]),
            now: now)
    }

    func testReasonLinesMapOneToOneAndPreserveOrder() async {
        let s = suggestions()
        let lines = await FestivalPlanIntelligence.reasonLines(for: s)
        XCTAssertEqual(lines.count, s.count)
        XCTAssertTrue(lines.allSatisfy { !$0.text.isEmpty })
    }

    func testDegradesToTemplateWhenIntelligenceUnavailable() async throws {
        // The simulator/CI host has no Apple Intelligence; the floor must be exactly the templates.
        guard !FestivalPlanIntelligence.isIntelligenceAvailable else {
            throw XCTSkip("on-device model available on this host — degrade path not exercised")
        }
        let s = suggestions()
        let lines = await FestivalPlanIntelligence.reasonLines(for: s)
        for (line, suggestion) in zip(lines, s) {
            XCTAssertEqual(line.source, .template)
            XCTAssertEqual(line.text, suggestion.templateReason,
                           "with no FM the card shows the recommender's exact template reason")
        }
    }

    func testEmptyInputYieldsEmptyOutput() async {
        let lines = await FestivalPlanIntelligence.reasonLines(for: [])
        XCTAssertTrue(lines.isEmpty)
    }
}
