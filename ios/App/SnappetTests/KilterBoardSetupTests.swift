import XCTest
@testable import Snappet

/// Pure tests for the "Set up this board" verifier (prompt 120): the `KilterBoardSetup.target` branch
/// (climb-vs-calibration) and the `KilterCalibration.pick` corner+center selection. No catalog, no BLE, no
/// device — the whole point of pulling these rules out of the SQL and the SwiftUI sheet.
final class KilterBoardSetupTests: XCTestCase {

    // MARK: - target(climbLayoutId:chosenLayoutId:chosenSizeId:)

    func testTargetLightsClimbWhenChosenLayoutMatchesClimb() {
        XCTAssertEqual(KilterBoardSetup.target(climbLayoutId: 1, chosenLayoutId: 1, chosenSizeId: 27),
                       .climb(sizeId: 27))
    }

    func testTargetCalibratesWhenChosenLayoutDiffersFromClimb() {
        XCTAssertEqual(KilterBoardSetup.target(climbLayoutId: 1, chosenLayoutId: 8, chosenSizeId: 27),
                       .calibration(layoutId: 8, sizeId: 27))
    }

    func testTargetCalibratesWhenNoClimb() {
        // The manual "Set up this board" entry has no open climb to light.
        XCTAssertEqual(KilterBoardSetup.target(climbLayoutId: nil, chosenLayoutId: 1, chosenSizeId: 27),
                       .calibration(layoutId: 1, sizeId: 27))
    }

    // MARK: - KilterCalibration.pick

    /// A helper making a hole with a synthetic led index (led value is irrelevant to selection geometry).
    private func hole(_ id: Int, _ x: Int, _ y: Int) -> KilterCalibration.Hole {
        KilterCalibration.Hole(holeId: id, x: x, y: y, led: id * 10)
    }

    func testPickEmptyIsEmpty() {
        XCTAssertTrue(KilterCalibration.pick(from: []).isEmpty)
    }

    func testPickReturnsFourCornersPlusCenterForAGrid() {
        // A 5×5 hole grid (coords 0,25,50,75,100) with a distinct hole at each intersection. The five
        // targets (corners + center) should each land on the exact corner/center hole.
        var holes: [KilterCalibration.Hole] = []
        var id = 1
        for y in stride(from: 0, through: 100, by: 25) {
            for x in stride(from: 0, through: 100, by: 25) {
                holes.append(hole(id, x, y)); id += 1
            }
        }
        let picked = KilterCalibration.pick(from: holes)
        // Corner-first, then center — deterministic order.
        let coords = picked.map { ($0.x, $0.y) }
        XCTAssertEqual(picked.count, 5)
        XCTAssertEqual(coords.map { "\($0.0),\($0.1)" },
                       ["0,0", "100,0", "0,100", "100,100", "50,50"])
    }

    func testPickChoosesNearestHoleWhenNoHoleSitsExactlyOnACorner() {
        // Corners of the extent are (0,0)…(100,100) but no hole sits on them; nearest wins.
        let holes = [
            hole(1, 5, 5),      // nearest to (0,0)
            hole(2, 95, 8),     // nearest to (100,0)
            hole(3, 3, 96),     // nearest to (0,100)
            hole(4, 92, 93),    // nearest to (100,100)
            hole(5, 48, 51),    // nearest to (50,50)
            hole(6, 50, 10),    // a decoy that shouldn't be picked
        ]
        let picked = KilterCalibration.pick(from: holes)
        XCTAssertEqual(picked.map(\.holeId), [1, 2, 3, 4, 5])
    }

    func testPickDedupesWhenTargetsCollapseToTheSameHole() {
        // Two holes only: corners collapse onto the two nearest, center picks whichever is closer — the
        // result is deduped by holeId, so at most the distinct holes appear (never a repeat).
        let holes = [hole(1, 0, 0), hole(2, 100, 100)]
        let picked = KilterCalibration.pick(from: holes)
        XCTAssertEqual(Set(picked.map(\.holeId)).count, picked.count)   // no duplicates
        XCTAssertTrue(Set(picked.map(\.holeId)).isSubset(of: [1, 2]))
        XCTAssertFalse(picked.isEmpty)
    }

    func testPickHandlesADegenerateSingleRow() {
        // All holes share y (a 1-D board): no crash, distinct holes, corner order still left→right.
        let holes = [hole(1, 0, 40), hole(2, 30, 40), hole(3, 60, 40), hole(4, 100, 40)]
        let picked = KilterCalibration.pick(from: holes)
        XCTAssertFalse(picked.isEmpty)
        XCTAssertEqual(Set(picked.map(\.holeId)).count, picked.count)
        // Left target family → leftmost hole; right target family → rightmost hole.
        XCTAssertTrue(picked.contains { $0.holeId == 1 })
        XCTAssertTrue(picked.contains { $0.holeId == 4 })
    }

    func testPickPreservesLedIndex() {
        let holes = [hole(7, 0, 0), hole(8, 100, 100), hole(9, 50, 50)]
        let picked = KilterCalibration.pick(from: holes)
        for p in picked { XCTAssertEqual(p.led, p.holeId * 10) }
    }
}
