import XCTest
@testable import Snappet

/// Unit coverage for the on-device generator's pure core — meta decoding + the autoregressive sampler +
/// the grade model — with a deterministic stub session (no ONNX Runtime, no model file, no device). The
/// real `KilterORTSession` only swaps in the logits; everything tested here is the algorithm.
final class KilterGeneratorTests: XCTestCase {

    /// A tiny but structurally-real meta: 14-token vocab, one size, the four roles, a hold mask, and a
    /// linear grade model. Mirrors the shape of the production `meta.json`.
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

    private func request(maxHolds: Int = 20, candidates: Int = 1) -> KilterGenerateRequest {
        KilterGenerateRequest(sizeId: 10, angle: 40, grade: 17, nomatch: false,
                              temperature: 0.9, maxHolds: maxHolds, minHolds: 4, candidates: candidates)
    }

    /// Returns uniform (zero) logits → the *RNG* decides the pick, making generation deterministic.
    private struct UniformSession: KilterLogitsProviding {
        let vocab: Int
        func logits(forTokens tokens: [Int]) throws -> [Float] { [Float](repeating: 0, count: vocab) }
    }

    // MARK: - Meta decoding + prep maps

    func testMetaDecodesAndBuildsMaps() throws {
        let m = try model()
        XCTAssertEqual(m.meta.block, 8)
        XCTAssertEqual(m.stoi["SIZE_10"], 5)
        XCTAssertEqual(m.placementOf[8], 100)   // HOLD_100_12
        XCTAssertEqual(m.roleOf[8], 12)
        XCTAssertEqual(m.roleName[14], "finish")
        XCTAssertNil(m.placementOf[5])          // SIZE_ token isn't a hold
    }

    // MARK: - Sampler

    /// rng() == 0 always picks the first candidate, so the climb is fully determined: start, middle,
    /// finish, foot, then EOS once a start+finish+min-length exist.
    func testDeterministicGeneration() throws {
        let m = try model()
        let gen = KilterClimbGenerator(model: m, session: UniformSession(vocab: m.meta.itos.count))
        let climb = try gen.generate(request()) { 0 }
        XCTAssertEqual(climb.frames, "p100r12p101r13p102r14p103r15")
        XCTAssertEqual(climb.holdTokens, [8, 9, 10, 11])
    }

    func testAlwaysHasStartAndFinish() throws {
        let m = try model()
        let gen = KilterClimbGenerator(model: m, session: UniformSession(vocab: m.meta.itos.count))
        // rng picks roughly the middle candidate each step — exercises a different path.
        var seq = 0
        let climb = try gen.generate(request()) { seq += 1; return 0.5 }
        let roles = Set(climb.holdTokens.compactMap { m.roleOf[$0].flatMap { m.roleName[$0] } })
        XCTAssertTrue(roles.contains("start"), "every generated climb must have a start")
        XCTAssertTrue(roles.contains("finish"), "every generated climb must have a finish")
    }

    /// When the loop stops before a finish appears, the repair pass forces one in.
    func testRepairAddsMissingFinish() throws {
        let m = try model()
        let gen = KilterClimbGenerator(model: m, session: UniformSession(vocab: m.meta.itos.count))
        // maxHolds 2 + rng 0 → [start(100), middle(101)] then loop ends with no finish; repair adds 102.
        let climb = try gen.generate(request(maxHolds: 2)) { 0 }
        let roleNames = climb.holdTokens.compactMap { m.roleOf[$0].flatMap { m.roleName[$0] } }
        XCTAssertTrue(roleNames.contains("start"))
        XCTAssertTrue(roleNames.contains("finish"))
    }

    func testNoDuplicatePlacements() throws {
        let m = try model()
        let gen = KilterClimbGenerator(model: m, session: UniformSession(vocab: m.meta.itos.count))
        let climb = try gen.generate(request()) { 0.3 }
        let placements = climb.holdTokens.compactMap { m.placementOf[$0] }
        XCTAssertEqual(placements.count, Set(placements).count, "a placement can't be used twice")
    }

    func testAllHoldsAreInSizeMask() throws {
        let m = try model()
        let mask = Set(m.meta.sizeMasks["10"]!)
        let gen = KilterClimbGenerator(model: m, session: UniformSession(vocab: m.meta.itos.count))
        let climb = try gen.generate(request()) { 0.7 }
        for token in climb.holdTokens {
            XCTAssertTrue(mask.contains(token), "generated token \(token) must be in the board-size mask")
        }
    }

    func testUnknownSizeThrows() throws {
        let m = try model()
        let gen = KilterClimbGenerator(model: m, session: UniformSession(vocab: m.meta.itos.count))
        var req = request(); req.sizeId = 999
        XCTAssertThrowsError(try gen.generate(req) { 0 })
    }

    // MARK: - Grade model

    func testPredictGradeMatchesLinearModel() throws {
        let m = try model()
        // bias 2 + w_angle[0] 0.5 + w_hold[8] 1.0 + y_mean 10 = 13.5
        let g = KilterClimbGenerator.predictGrade(model: m, holds: [8], angle: 40, nomatch: false)
        XCTAssertEqual(g, 13.5, accuracy: 1e-9)
        // nomatch adds w_nomatch 1.0
        let gn = KilterClimbGenerator.predictGrade(model: m, holds: [8], angle: 40, nomatch: true)
        XCTAssertEqual(gn, 14.5, accuracy: 1e-9)
    }

    // MARK: - Softmax sampling primitive

    func testSampleHonorsRNGBoundaries() {
        // Equal weights, three tokens. rng→0 picks the first; rng→~1 picks the last.
        XCTAssertEqual(KilterClimbGenerator.sample(weights: [0, 0, 0], tokens: [7, 8, 9]) { 0 }, 7)
        XCTAssertEqual(KilterClimbGenerator.sample(weights: [0, 0, 0], tokens: [7, 8, 9]) { 0.999 }, 9)
    }
}
