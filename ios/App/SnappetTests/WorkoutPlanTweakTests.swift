import XCTest
@testable import Snappet

/// Unit tests for the natural-language tweak seam (workout-redesign E7): the always-on heuristic parser
/// (`WorkoutPlanTweakParser`) and the `WorkoutPlanIntelligence` degrade-to-heuristic guarantee. The
/// FoundationModels call itself is SDK/device-gated; these tests pin the deterministic floor + the seam
/// that must hold even when the on-device model is unavailable (the locked-decision constraint).
final class WorkoutPlanTweakTests: XCTestCase {

    // MARK: - Heuristic parser

    func testEmptyPhraseIsNoTweak() {
        XCTAssertTrue(WorkoutPlanTweakParser.parse("").isEmpty)
        XCTAssertTrue(WorkoutPlanTweakParser.parse("   ").isEmpty)
    }

    func testNoBarbell() {
        let t = WorkoutPlanTweakParser.parse("no barbell today")
        XCTAssertTrue(t.excludedEquipment.contains(.barbell))
        XCTAssertFalse(t.bodyweightOnly)
    }

    func testNoEquipmentMeansBodyweight() {
        XCTAssertTrue(WorkoutPlanTweakParser.parse("no equipment").bodyweightOnly)
        XCTAssertTrue(WorkoutPlanTweakParser.parse("bodyweight only").bodyweightOnly)
        XCTAssertTrue(WorkoutPlanTweakParser.parse("hotel workout").bodyweightOnly)
    }

    func testTimeCapMapsToCountAndTimeCapped() {
        let t = WorkoutPlanTweakParser.parse("15 min")
        XCTAssertEqual(t.targetCount, 3, "~1 exercise per 5 min, clamped")
        XCTAssertEqual(t.strategy, .timeCapped)
    }

    func testGluedTimeCap() {
        let t = WorkoutPlanTweakParser.parse("20min please")
        XCTAssertEqual(t.targetCount, 4)
    }

    func testExplicitMoveCountWins() {
        let t = WorkoutPlanTweakParser.parse("just 4 exercises")
        XCTAssertEqual(t.targetCount, 4)
    }

    func testStrategyIntent() {
        XCTAssertEqual(WorkoutPlanTweakParser.parse("go heavy").strategy, .strength)
        XCTAssertEqual(WorkoutPlanTweakParser.parse("easy day").strategy, .recovery)
        XCTAssertEqual(WorkoutPlanTweakParser.parse("pump session").strategy, .hypertrophy)
    }

    func testCombinedTweak() {
        let t = WorkoutPlanTweakParser.parse("15 min, no barbell")
        XCTAssertEqual(t.targetCount, 3)
        XCTAssertTrue(t.excludedEquipment.contains(.barbell))
    }

    // MARK: - apply(to:)

    func testApplyFoldsOntoOptions() {
        var t = WorkoutPlanTweak.none
        t.targetCount = 4
        t.excludedEquipment = [.barbell]
        t.bodyweightOnly = false
        let base = WorkoutRecommender.Options(targetCount: 6, excludedEquipment: [.machine])
        let merged = t.apply(to: base)
        XCTAssertEqual(merged.targetCount, 4, "Count overrides")
        XCTAssertEqual(merged.excludedEquipment, [.barbell, .machine], "Exclusions union")
    }

    // MARK: - Degrade-to-heuristic seam

    func testIntelligenceResolveDegradesToHeuristicWhenUnavailable() async {
        // On the simulator / CI the on-device model is not available, so resolve() must return the
        // heuristic parse — proving the seam never breaks the always-on path. (On a capable iOS 26 device
        // this may instead return .appleIntelligence; either way the tweak is non-empty for this phrase.)
        let result = await WorkoutPlanIntelligence.resolve(phrase: "no barbell, 15 min")
        XCTAssertTrue(result.tweak.excludedEquipment.contains(.barbell) || result.tweak.targetCount != nil,
                      "A real tweak is produced by whichever path runs")
        if !WorkoutPlanIntelligence.isIntelligenceAvailable {
            XCTAssertEqual(result.source, .heuristic, "With FM unavailable, the heuristic path is used")
            XCTAssertEqual(result.tweak, WorkoutPlanTweakParser.parse("no barbell, 15 min"))
        }
    }

    func testEmptyPhraseResolvesToNoTweakHeuristic() async {
        let result = await WorkoutPlanIntelligence.resolve(phrase: "  ")
        XCTAssertEqual(result.source, .heuristic)
        XCTAssertTrue(result.tweak.isEmpty)
    }
}
