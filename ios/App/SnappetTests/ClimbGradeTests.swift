import XCTest
@testable import Snappet

/// Unit tests for the **pure** climb type + grade-scale value types (Quick Session redesign) — no
/// SwiftUI, no SwiftData, no device. Grades must be a constrained, ordered, scale-aware set so the
/// pyramid / hardest-send math is exact.
final class ClimbGradeTests: XCTestCase {

    // MARK: - ClimbType

    func testTypeRouteFlag() {
        XCTAssertFalse(ClimbType.boulder.isRoute)
        XCTAssertTrue(ClimbType.topRope.isRoute)
        XCTAssertTrue(ClimbType.lead.isRoute)
        XCTAssertTrue(ClimbType.sport.isRoute)
    }

    func testDefaultScalePerType() {
        XCTAssertEqual(ClimbType.boulder.defaultScale, .vScale)
        XCTAssertEqual(ClimbType.topRope.defaultScale, .yds)
        XCTAssertEqual(ClimbType.lead.defaultScale, .yds)
        XCTAssertEqual(ClimbType.sport.defaultScale, .yds)
    }

    func testBoulderStatusLabelsArePlain() {
        XCTAssertEqual(ClimbType.boulder.statusLabel(.flash), "Flash")
        XCTAssertEqual(ClimbType.boulder.statusLabel(.sent), "Sent")
        XCTAssertEqual(ClimbType.boulder.statusLabel(.project), "Project")
        XCTAssertEqual(ClimbType.boulder.statusLabel(.attempt), "Attempt")
    }

    func testRouteStatusLabelsRelabelWithoutChangingEnum() {
        XCTAssertEqual(ClimbType.lead.statusLabel(.flash), "Onsight")
        XCTAssertEqual(ClimbType.lead.statusLabel(.sent), "Redpoint")
        XCTAssertEqual(ClimbType.lead.statusLabel(.project), "Project")
        XCTAssertEqual(ClimbType.lead.statusLabel(.attempt), "Fell")
        // The underlying send semantics are unchanged (Onsight/Redpoint still count as sends).
        XCTAssertTrue(KilterAscentStatus.flash.isSend)
        XCTAssertTrue(KilterAscentStatus.sent.isSend)
    }

    func testScalesTogglesPrimaryThenCompanion() {
        XCTAssertEqual(ClimbType.boulder.scales(selected: nil), [.vScale, .font])
        XCTAssertEqual(ClimbType.boulder.scales(selected: .font), [.font, .vScale])
        XCTAssertEqual(ClimbType.lead.scales(selected: nil), [.yds, .french])
    }

    // MARK: - GradeScale

    func testRungsAreOrderedAndNonEmpty() {
        for scale in GradeScale.allCases {
            XCTAssertFalse(scale.rungs.isEmpty, "\(scale) has rungs")
            // Difficulty is the index → strictly increasing and unique.
            let diffs = scale.rungs.map { scale.difficulty(for: $0) }
            XCTAssertEqual(diffs, (0..<scale.rungs.count).map { Double($0) },
                           "\(scale) difficulty is the rung index")
            XCTAssertEqual(Set(scale.rungs).count, scale.rungs.count, "\(scale) rungs are unique")
        }
    }

    func testKnownGradeDifficultyMonotonic() {
        XCTAssertLessThan(GradeScale.vScale.difficulty(for: "V3")!, GradeScale.vScale.difficulty(for: "V8")!)
        XCTAssertLessThan(GradeScale.yds.difficulty(for: "5.10a")!, GradeScale.yds.difficulty(for: "5.12b")!)
        XCTAssertLessThan(GradeScale.font.difficulty(for: "6A")!, GradeScale.font.difficulty(for: "7B")!)
        XCTAssertLessThan(GradeScale.french.difficulty(for: "6a")!, GradeScale.french.difficulty(for: "8a")!)
    }

    func testUnknownGradeHasNoDifficulty() {
        XCTAssertNil(GradeScale.vScale.difficulty(for: "5.11a")) // wrong scale
        XCTAssertNil(GradeScale.vScale.difficulty(for: "nonsense"))
        XCTAssertNil(GradeScale.yds.difficulty(for: ""))
    }

    func testCompanionRoundTrips() {
        for scale in GradeScale.allCases {
            XCTAssertEqual(scale.companion.companion, scale, "\(scale) companion round-trips")
        }
        XCTAssertEqual(GradeScale.vScale.companion, .font)
        XCTAssertEqual(GradeScale.yds.companion, .french)
    }

    func testBoulderScaleFlag() {
        XCTAssertTrue(GradeScale.vScale.isBoulderScale)
        XCTAssertTrue(GradeScale.font.isBoulderScale)
        XCTAssertFalse(GradeScale.yds.isBoulderScale)
        XCTAssertFalse(GradeScale.french.isBoulderScale)
    }

    func testDefaultGradeIsAValidRung() {
        for scale in GradeScale.allCases {
            XCTAssertTrue(scale.rungs.contains(scale.defaultGrade),
                          "\(scale).defaultGrade (\(scale.defaultGrade)) is a real rung")
        }
    }

    // MARK: - ClimbColor

    func testClimbColorPaletteIsDistinctAndLabelled() {
        let all = ClimbColor.allCases
        XCTAssertGreaterThanOrEqual(all.count, 10)
        // Every colour has a distinct hex + a capitalised label, and round-trips through its rawValue.
        XCTAssertEqual(Set(all.map(\.hexValue)).count, all.count, "swatch hexes are distinct")
        for c in all {
            XCTAssertEqual(c.label, c.rawValue.capitalized)
            XCTAssertEqual(ClimbColor(rawValue: c.rawValue), c)
        }
        XCTAssertTrue(ClimbColor.white.needsRing, "white needs a ring to read on a light card")
        XCTAssertFalse(ClimbColor.blue.needsRing)
        XCTAssertNil(ClimbColor(rawValue: "chartreuse"))
    }

    // MARK: - Per-gym wall / recents merge (AddClimbSheet.mergedRecents)

    func testMergedRecentsIsMostRecentFirstDedupedAndCapped() {
        // most-recent-first, case-insensitive dedupe, capped.
        var r = AddClimbSheet.mergedRecents([], adding: "Cave", cap: 6)
        XCTAssertEqual(r, ["Cave"])
        r = AddClimbSheet.mergedRecents(r, adding: "Slab", cap: 6)
        XCTAssertEqual(r, ["Slab", "Cave"])
        r = AddClimbSheet.mergedRecents(r, adding: "cave", cap: 6)        // dedupe case-insensitively, re-promote
        XCTAssertEqual(r, ["cave", "Slab"])
        // blank is ignored; trims whitespace.
        XCTAssertEqual(AddClimbSheet.mergedRecents(["A"], adding: "   ", cap: 6), ["A"])
        XCTAssertEqual(AddClimbSheet.mergedRecents([], adding: "  Roof  ", cap: 6), ["Roof"])
        // cap holds the newest.
        let capped = ["e", "d", "c", "b", "a"].reduce(into: [String]()) { acc, x in
            acc = AddClimbSheet.mergedRecents(acc, adding: x, cap: 3)
        }
        XCTAssertEqual(capped, ["a", "b", "c"])
    }
}
