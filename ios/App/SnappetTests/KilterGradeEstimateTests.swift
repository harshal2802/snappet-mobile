import XCTest
@testable import Snappet

/// Pure coverage for the create-climb lifecycle's two model-touching helpers (#76): the manual-tab live
/// grade estimate (`holdTokens` / `estimateManualGrade`) and the frames⇄assignments round trip the editor
/// uses to re-open a saved climb. No ONNX runtime, no SwiftData — these run with no simulator.
final class KilterGradeEstimateTests: XCTestCase {

    /// A tiny structurally-real meta (mirrors `KilterGeneratorTests`): the four roles, a six-hold vocab,
    /// and a linear grade model where `HOLD_100_12` weighs 1.0 and `HOLD_104_12` weighs 0.7.
    private static let metaJSON = """
    {
      "block": 8, "pad": 0,
      "specials": {"BOS": 1, "EOS": 2, "PAD": 0, "MATCH": 3, "NOMATCH": 4},
      "firstHoldId": 8,
      "itos": ["PAD","BOS","EOS","MATCH","NOMATCH","SIZE_10","ANGLE_40","GRADE_17",
               "HOLD_100_12","HOLD_101_13","HOLD_102_14","HOLD_103_15","HOLD_104_12","HOLD_105_14"],
      "sizes": [{"id": 10, "name": "12 x 12", "box": [0,144,0,156]}],
      "roles": [{"id":12,"name":"start","color":"00DD00"},{"id":13,"name":"middle","color":"00FFFF"},
                {"id":14,"name":"finish","color":"FF00FF"},{"id":15,"name":"foot","color":"FFA500"}],
      "sizeMasks": {"10": [2,8,9,10,11,12,13]},
      "gradeModel": {
        "w_hold": [0,0,0,0,0,0,0,0,1.0,0,0,0,0.7,0],
        "w_angle": [0.5], "w_nomatch": 1.0, "bias": 2.0,
        "angle_index": {"40": 0}, "y_mean": 10.0, "first_hold_id": 8
      },
      "grades": [17], "gradeLabels": {"17": "6a/V3"}, "angles": [40], "defaultSize": 10
    }
    """

    private func model() throws -> KilterGeneratorModel {
        let meta = try JSONDecoder().decode(KilterGeneratorMeta.self, from: Data(Self.metaJSON.utf8))
        return KilterGeneratorModel(meta)
    }

    // MARK: - holdTokens

    func testHoldTokensMapAssignmentsThroughTheVocab() throws {
        let m = try model()
        let tokens = KilterClimbGenerator.holdTokens(
            forAssignments: [100: .start, 101: .middle], model: m)
        XCTAssertEqual(tokens.sorted(), [8, 9], "HOLD_100_12 → 8, HOLD_101_13 → 9")
    }

    func testHoldTokensDropOutOfVocabHoldsGracefully() throws {
        let m = try model()
        // 999 was never seen; 100 as a *foot* (role 15) isn't a vocab token either — both dropped.
        let tokens = KilterClimbGenerator.holdTokens(
            forAssignments: [999: .start, 100: .foot, 102: .finish], model: m)
        XCTAssertEqual(tokens, [10], "only HOLD_102_14 resolves")
    }

    // MARK: - estimateManualGrade

    func testEstimateMatchesPredictGradeOverResolvedHolds() throws {
        let m = try model()
        // tokens [8] → bias 2.0 + angle 0.5 + w_hold[8] 1.0 + y_mean 10.0 = 13.5
        let estimate = KilterClimbGenerator.estimateManualGrade(
            assignments: [100: .start], angle: 40, nomatch: false, model: m)
        XCTAssertEqual(try XCTUnwrap(estimate), 13.5, accuracy: 1e-9)
    }

    func testEstimateAddsNoMatchTerm() throws {
        let m = try model()
        let plain = KilterClimbGenerator.estimateManualGrade(
            assignments: [100: .start], angle: 40, nomatch: false, model: m)
        let nomatch = KilterClimbGenerator.estimateManualGrade(
            assignments: [100: .start], angle: 40, nomatch: true, model: m)
        XCTAssertEqual(try XCTUnwrap(nomatch) - XCTUnwrap(plain), 1.0, accuracy: 1e-9, "w_nomatch = 1.0")
    }

    func testEstimateIsNilWhenNoHoldResolves() throws {
        let m = try model()
        XCTAssertNil(KilterClimbGenerator.estimateManualGrade(
            assignments: [:], angle: 40, nomatch: false, model: m), "empty → nothing to estimate")
        XCTAssertNil(KilterClimbGenerator.estimateManualGrade(
            assignments: [999: .start], angle: 40, nomatch: false, model: m), "all out-of-vocab → nil")
    }

    // MARK: - frames ⇄ assignments (editor re-open)

    func testAssignmentsRoundTripThroughFrames() {
        let original: [Int: KilterAuthorRole] = [100: .start, 101: .middle, 102: .finish, 103: .foot]
        let frames = kilterFrames(from: original)
        XCTAssertEqual(CreateClimbView.assignments(fromFrames: frames), original,
                       "re-opening a saved climb restores exactly its placed holds")
    }

    func testAssignmentsParseIgnoresUnknownRoleIds() {
        // A role id outside 12–15 isn't an author role — skipped rather than crashing.
        XCTAssertEqual(CreateClimbView.assignments(fromFrames: "p100r12p200r99"),
                       [100: .start], "the unknown r99 placement is dropped")
    }
}
