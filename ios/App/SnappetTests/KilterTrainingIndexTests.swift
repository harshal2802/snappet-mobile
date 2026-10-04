import XCTest
@testable import Snappet

/// Prompt 155: "was this generated climb in the model's training data?" — the pure matcher over the
/// published training index (one row per climb with its split).
final class KilterTrainingIndexTests: XCTestCase {
    /// p1r12 = placement 1 as a start; roles 12 start · 13 hand · 14 finish · 15 foot.
    private func row(_ uuid: String, _ frames: String, _ split: String, ascents: Int = 10) -> [Any] {
        [uuid, "Climb \(uuid)", "setter", split, frames, ascents, 40, "6c/V5"]
    }

    private func index(_ rows: [[Any]]) throws -> KilterTrainingIndex {
        let json: [String: Any] = [
            "version": 1, "snapshotGeneratedAt": "2026-06-06",
            "fields": ["uuid", "name", "setter", "split", "frames", "ascents", "angle", "grade"],
            "climbs": rows,
        ]
        return try KilterTrainingIndex.decode(JSONSerialization.data(withJSONObject: json))
    }

    func testDecodesThePublishedShape() throws {
        let idx = try index([row("A", "p1r12p2r13p3r14", "train"), row("B", "p4r12p5r14", "val")])
        XCTAssertEqual(idx.climbs.count, 2)
        XCTAssertEqual(idx.snapshot, "2026-06-06")
        XCTAssertEqual(idx.climbs[0].placements, [1, 2, 3])
        XCTAssertEqual(idx.climbs[1].split, .val)
        XCTAssertThrowsError(try KilterTrainingIndex.decode(Data("nope".utf8)))
    }

    func testAnExactCopyOfATrainingClimbIsInTraining() throws {
        let idx = try index([row("A", "p1r12p2r13p3r14", "train")])
        let m = idx.check(frames: "p3r14p1r12p2r13")   // any hold order
        XCTAssertEqual(m.kind, .inTraining)
        XCTAssertEqual(m.climb?.uuid, "A")
    }

    func testAnExactHeldOutClimbIsAnIndependentRediscovery() throws {
        let idx = try index([row("V", "p1r12p2r13p3r14", "val"), row("T", "p7r12p8r14", "test")])
        XCTAssertEqual(idx.check(frames: "p1r12p2r13p3r14").kind, .heldOut(.val))
        XCTAssertEqual(idx.check(frames: "p7r12p8r14").kind, .heldOut(.test))
    }

    func testEightyPercentSharedIsVeryClose() throws {
        // 4 of 5 holds shared = 0.8.
        let idx = try index([row("A", "p1r12p2r13p3r13p4r13p5r14", "train")])
        let m = idx.check(frames: "p1r12p2r13p3r13p4r13p9r14")
        XCTAssertEqual(m.kind, .veryClose)
        XCTAssertEqual(m.shared, 4)
        XCTAssertEqual(m.outOf, 5)
        XCTAssertFalse(m.sameHoldsDifferentRoles)
        // 3 of 5 = 0.6 → new, but it still names the nearest climb.
        let far = idx.check(frames: "p1r12p2r13p3r13p8r13p9r14")
        XCTAssertEqual(far.kind, .new)
        XCTAssertEqual(far.climb?.uuid, "A")
        XCTAssertEqual(far.shared, 3)
    }

    func testSameHoldsWithDifferentRolesIsVeryClose() throws {
        let idx = try index([row("A", "p1r12p2r13p3r14", "train")])
        let m = idx.check(frames: "p1r12p2r14p3r13")
        XCTAssertEqual(m.kind, .veryClose)
        XCTAssertTrue(m.sameHoldsDifferentRoles)
    }

    func testExtraHoldsCountAgainstSimilarity() throws {
        // The generated climb has all 4 of A's holds plus 2 more: 4 / 6 shared ≈ 0.67 → not "very close".
        let idx = try index([row("A", "p1r12p2r13p3r13p4r14", "train")])
        let m = idx.check(frames: "p1r12p2r13p3r13p4r14p5r13p6r15")
        XCTAssertEqual(m.kind, .new)
        XCTAssertEqual(m.outOf, 6)
    }

    func testNearestIsATrainingClimbAndTiesPreferTheMoreClimbed() throws {
        let idx = try index([
            row("held", "p1r12p2r13p3r14", "val"),                 // closer, but never trained on
            row("few", "p1r12p2r13p9r14", "train", ascents: 4),
            row("many", "p1r12p2r13p8r14", "train", ascents: 400),
        ])
        let m = idx.check(frames: "p1r12p2r13p7r14")
        XCTAssertEqual(m.climb?.uuid, "many")
        XCTAssertEqual(m.kind, .new)
    }

    func testNothingInCommon() throws {
        let idx = try index([row("A", "p1r12p2r14", "train")])
        let m = idx.check(frames: "p5r12p6r14")
        XCTAssertEqual(m.kind, .new)
        XCTAssertNil(m.climb)
        XCTAssertEqual(idx.check(frames: "").kind, .new)
    }
}
