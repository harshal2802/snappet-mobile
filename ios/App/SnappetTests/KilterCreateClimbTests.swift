import XCTest
@testable import Snappet

/// Unit coverage for authoring a new climb (manual editor + generator share this core): the
/// content-derived identity is deterministic and cross-device stable, frames build canonically, the
/// save floor (start/finish/min holds) is enforced, role cycling is correct, and the duplicate check
/// catches an existing catalog/created climb regardless of hold order. All pure — no simulator, no
/// device, no catalog (hand-built rows).
final class KilterCreateClimbTests: XCTestCase {

    // MARK: - Canonicalization + identity

    func testCanonicalFramesIsOrderIndependent() {
        let a = KilterClimbIdentity.canonicalFrames("p25r14p1r12p13r13")
        let b = KilterClimbIdentity.canonicalFrames("p1r12p13r13p25r14")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "p1r12p13r13p25r14")   // sorted ascending by placement
    }

    func testCanonicalFramesDropsMalformedTokens() {
        // A junk token between two valid ones is dropped; the valid holds survive (matches parseFrames).
        XCTAssertEqual(KilterClimbIdentity.canonicalFrames("p1r12pgarbagep13r13"), "p1r12p13r13")
    }

    /// The crux of the brief: the SAME holds → the SAME uuid, every time, on any device.
    func testUUIDIsDeterministicAndOrderIndependent() {
        let u1 = KilterClimbIdentity.uuid(forLayout: 1, frames: "p25r14p1r12p13r13")
        let u2 = KilterClimbIdentity.uuid(forLayout: 1, frames: "p1r12p13r13p25r14")
        XCTAssertEqual(u1, u2, "two devices building the same climb in any order must converge on one uuid")
    }

    /// Golden vector — pins the exact UUIDv5 so a refactor that silently changes the hash (and thus
    /// re-keys every created climb) fails loudly. Cross-checked against an independent implementation.
    func testUUIDGoldenVector() {
        XCTAssertEqual(KilterClimbIdentity.uuid(forLayout: 1, frames: "p1r12p13r13p25r14"),
                       "d4e7b15e-a007-582c-8e1c-b143ddde0503")
    }

    func testUUIDIsLayoutScoped() {
        let l1 = KilterClimbIdentity.uuid(forLayout: 1, frames: "p1r12p13r13p25r14")
        let l2 = KilterClimbIdentity.uuid(forLayout: 2, frames: "p1r12p13r13p25r14")
        XCTAssertNotEqual(l1, l2, "the same placement ids on a different layout are a different climb")
    }

    func testUUIDHasVersion5AndRFCVariant() {
        let u = KilterClimbIdentity.uuid(forLayout: 1, frames: "p1r12p13r13p25r14")
        let chars = Array(u)
        XCTAssertEqual(chars[14], "5", "version nibble must be 5 (name-based SHA-1)")
        XCTAssertTrue("89ab".contains(chars[19]), "variant nibble must be 8/9/a/b (RFC 4122)")
    }

    // MARK: - Frames building from authored assignments

    func testFramesFromAssignmentsIsCanonical() {
        let frames = kilterFrames(from: [13: .middle, 1: .start, 25: .finish])
        XCTAssertEqual(frames, "p1r12p13r13p25r14")   // sorted, role ids 12/13/14
    }

    func testEmptyAssignmentsFramesIsEmpty() {
        XCTAssertEqual(kilterFrames(from: [:]), "")
    }

    // MARK: - Author roles

    func testRoleIdMapping() {
        XCTAssertEqual(KilterAuthorRole.start.roleId, 12)
        XCTAssertEqual(KilterAuthorRole.middle.roleId, 13)
        XCTAssertEqual(KilterAuthorRole.finish.roleId, 14)
        XCTAssertEqual(KilterAuthorRole.foot.roleId, 15)
    }

    func testRoleRoundTripsThroughId() {
        for role in KilterAuthorRole.allCases {
            XCTAssertEqual(KilterAuthorRole(roleId: role.roleId), role)
        }
        XCTAssertEqual(KilterAuthorRole(roleId: 42), .start)   // alt-product alias
        XCTAssertNil(KilterAuthorRole(roleId: 99))
    }

    func testRoleCycleOrder() {
        XCTAssertEqual(KilterAuthorRole.start.next, .middle)
        XCTAssertEqual(KilterAuthorRole.middle.next, .finish)
        XCTAssertEqual(KilterAuthorRole.finish.next, .foot)
        XCTAssertNil(KilterAuthorRole.foot.next)   // foot → unset
    }

    // MARK: - Validation floor

    func testValidationRequiresStartFinishAndMinHolds() {
        XCTAssertEqual(kilterValidate([:]), .tooFewHolds(have: 0, need: 4))
        // 4 holds but no start
        let noStart: [Int: KilterAuthorRole] = [1: .middle, 2: .middle, 3: .finish, 4: .foot]
        XCTAssertEqual(kilterValidate(noStart), .missingStart)
        // start but no finish
        let noFinish: [Int: KilterAuthorRole] = [1: .start, 2: .middle, 3: .middle, 4: .foot]
        XCTAssertEqual(kilterValidate(noFinish), .missingFinish)
        // complete
        let ok: [Int: KilterAuthorRole] = [1: .start, 2: .middle, 3: .finish, 4: .foot]
        XCTAssertNil(kilterValidate(ok))
    }

    // MARK: - Duplicate detection

    private func checker() -> KilterDuplicateChecker {
        KilterDuplicateChecker(
            catalogRows: [
                (uuid: "cat-1", name: "Existing", setter: "Setter", frames: "p1r12p13r13p25r14"),
                (uuid: "cat-2", name: "Other", setter: "Setter", frames: "p2r12p9r14"),
            ],
            createdClimbs: [
                (uuid: "mine-1", name: "My Climb", setter: "You", layoutId: 1, frames: "p5r12p6r14p7r13p8r13"),
            ],
            layoutId: 1)
    }

    func testDuplicateMatchesCatalogRegardlessOfOrder() {
        let dup = checker().find(layoutId: 1, frames: "p25r14p13r13p1r12")   // same holds, shuffled
        XCTAssertEqual(dup?.uuid, "cat-1")
        XCTAssertEqual(dup?.origin, .catalog)
    }

    func testDuplicateMatchesCreatedClimb() {
        let dup = checker().find(layoutId: 1, frames: "p8r13p7r13p6r14p5r12")
        XCTAssertEqual(dup?.uuid, "mine-1")
        XCTAssertEqual(dup?.origin, .created)
    }

    func testNoDuplicateForNewHolds() {
        XCTAssertNil(checker().find(layoutId: 1, frames: "p100r12p101r14p102r13p103r13"))
    }

    func testDuplicateIsLayoutScoped() {
        // Same frames as cat-1 but a different layout → not a duplicate (the checker is layout-1 only).
        XCTAssertNil(checker().find(layoutId: 2, frames: "p1r12p13r13p25r14"))
    }

    func testCreatedClimbShadowsCatalogWithSameHolds() {
        let c = KilterDuplicateChecker(
            catalogRows: [(uuid: "cat", name: "Cat", setter: "S", frames: "p1r12p2r14p3r13p4r13")],
            createdClimbs: [(uuid: "mine", name: "Mine", setter: "You", layoutId: 1,
                             frames: "p1r12p2r14p3r13p4r13")],
            layoutId: 1)
        XCTAssertEqual(c.find(layoutId: 1, frames: "p1r12p2r14p3r13p4r13")?.origin, .created)
    }
}
