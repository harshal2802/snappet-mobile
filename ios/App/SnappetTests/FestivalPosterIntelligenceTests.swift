import XCTest
@testable import Snappet

/// The E7 seam for poster scanning (festival prompt 06): the on-device Foundation Models pass
/// restructures the OCR text, and degrades silently to the pure `FestivalPosterParser` floor. On the
/// test host Apple Intelligence is unavailable, so this asserts the guaranteed floor — the same draft
/// the parser produces, marked `.heuristic`.
final class FestivalPosterIntelligenceTests: XCTestCase {

    private let poster = """
    Sunset Sounds 2026
    Riverside Park
    2026-08-15
    MAIN STAGE
    18:00 Opening Act
    21:00 - 22:30 Neon Parade
    """

    func testDegradesToTheHeuristicFloorWhenIntelligenceUnavailable() async throws {
        guard !FestivalPosterIntelligence.isIntelligenceAvailable else {
            throw XCTSkip("on-device model available on this host — degrade path not exercised")
        }
        let draft = await FestivalPosterIntelligence.draft(fromOCR: poster, defaultOffsetSeconds: 0)
        let floor = FestivalPosterParser.parse(ocrText: poster, defaultOffsetSeconds: 0)

        XCTAssertEqual(draft.source, .heuristic, "with no FM the review form gets the pure floor draft")
        XCTAssertEqual(draft.name, floor.name)
        XCTAssertEqual(draft.allSetCount, floor.allSetCount)
        XCTAssertEqual(draft.days.map(\.date), floor.days.map(\.date))
        XCTAssertEqual(draft.days.first?.stages.map(\.name), floor.days.first?.stages.map(\.name))
    }

    func testAlwaysReturnsAUsableDraftEvenForGarbage() async {
        let draft = await FestivalPosterIntelligence.draft(fromOCR: "??? nothing", defaultOffsetSeconds: 0)
        // Never nil, never a crash — the capture flow always lands the user in an editable draft.
        XCTAssertFalse(draft.name.isEmpty)
    }
}
