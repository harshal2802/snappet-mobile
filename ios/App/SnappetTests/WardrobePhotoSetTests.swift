import XCTest
@testable import Snappet

/// Ordering, role assignment, the cap, and cover promotion for multi-photo garments
/// (wardrobe prompt 04). Pure — no store, no simulator.
final class WardrobePhotoSetTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()

    // MARK: ordering

    func testCoverSortsFirstThenExtrasInGivenOrder() {
        let out = WardrobePhotoSet.ordered(coverRole: .front,
                                           extras: [(a, .back), (b, .worn)])
        XCTAssertEqual(out.map(\.role), [.front, .back, .worn])
        XCTAssertEqual(out.map(\.id), [nil, a, b])
        XCTAssertTrue(out[0].isCover)
        XCTAssertFalse(out[1].isCover)
    }

    /// A garment whose cover was cleared but which still has extras must not silently lose them.
    func testNoCoverStillListsExtras() {
        let out = WardrobePhotoSet.ordered(coverRole: nil, extras: [(a, .worn)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, a)
        XCTAssertFalse(out[0].isCover)
    }

    func testNoPhotosAtAll() {
        XCTAssertTrue(WardrobePhotoSet.ordered(coverRole: nil, extras: []).isEmpty)
    }

    // MARK: the cap

    func testCapRefusesTheSeventhPhotoWithAReason() {
        XCTAssertTrue(WardrobePhotoSet.canAdd(currentCount: 5))
        XCTAssertNil(WardrobePhotoSet.addRefusalReason(currentCount: 5))
        XCTAssertFalse(WardrobePhotoSet.canAdd(currentCount: 6))
        let reason = WardrobePhotoSet.addRefusalReason(currentCount: 6)
        XCTAssertNotNil(reason, "a refused add must be explained, not silently dropped")
        XCTAssertTrue(reason!.contains("6"))
    }

    // MARK: role assignment

    func testNextUnusedRoleWalksTheCommonPath() {
        XCTAssertEqual(WardrobePhotoSet.nextUnusedRole(used: []), .front)
        XCTAssertEqual(WardrobePhotoSet.nextUnusedRole(used: [.front]), .back)
        XCTAssertEqual(WardrobePhotoSet.nextUnusedRole(used: [.front, .back]), .worn)
    }

    /// `detail` is the one role that legitimately repeats — several close-ups of one jacket.
    func testNextUnusedRoleFallsBackToDetailWhenAllUsed() {
        XCTAssertEqual(WardrobePhotoSet.nextUnusedRole(used: GarmentPhotoRole.allCases), .detail)
    }

    // MARK: sort indices

    /// Max+1, not count — a set that has had deletions must not collide on a live index.
    func testNextSortIndexSurvivesDeletions() {
        XCTAssertEqual(WardrobePhotoSet.nextSortIndex(existing: []), 0)
        XCTAssertEqual(WardrobePhotoSet.nextSortIndex(existing: [0, 1, 2]), 3)
        XCTAssertEqual(WardrobePhotoSet.nextSortIndex(existing: [0, 5]), 6,
                       "index 5 is still in use — reusing 2 would collide on order")
    }

    func testRenumberedProducesATotalOrderFromZero() {
        let map = WardrobePhotoSet.renumbered([c, a, b])
        XCTAssertEqual(map[c], 0)
        XCTAssertEqual(map[a], 1)
        XCTAssertEqual(map[b], 2)
    }

    // MARK: delete / cover promotion

    func testDeletingAnExtraLeavesTheCoverAlone() {
        let target = WardrobePhotoSet.Entry(id: a, role: .back)
        XCTAssertEqual(WardrobePhotoSet.deletePlan(target: target, extras: [(a, .back)]),
                       .removeExtra(id: a))
    }

    /// The case that would otherwise leave a photographed garment showing a category emoji.
    func testDeletingTheCoverPromotesTheNextPhoto() {
        let cover = WardrobePhotoSet.Entry(id: nil, role: .front, isCover: true)
        XCTAssertEqual(
            WardrobePhotoSet.deletePlan(target: cover, extras: [(a, .back), (b, .worn)]),
            .promoteThenRemove(promoting: a, role: .back))
    }

    func testDeletingTheCoverOfATwoPhotoSetPromotesTheOnlyOther() {
        let cover = WardrobePhotoSet.Entry(id: nil, role: .front, isCover: true)
        XCTAssertEqual(WardrobePhotoSet.deletePlan(target: cover, extras: [(b, .tag)]),
                       .promoteThenRemove(promoting: b, role: .tag))
    }

    func testDeletingTheOnlyPhotoClearsTheCover() {
        let cover = WardrobePhotoSet.Entry(id: nil, role: .front, isCover: true)
        XCTAssertEqual(WardrobePhotoSet.deletePlan(target: cover, extras: []), .clearCover)
    }

    // MARK: chrome

    /// A one-photo garment must look exactly as it did before prompt 04 — no dots, no caption.
    func testPagerChromeOnlyAppearsWithMoreThanOnePhoto() {
        XCTAssertFalse(WardrobePhotoSet.showsPagerChrome(photoCount: 0))
        XCTAssertFalse(WardrobePhotoSet.showsPagerChrome(photoCount: 1))
        XCTAssertTrue(WardrobePhotoSet.showsPagerChrome(photoCount: 2))
    }

    // MARK: roles

    /// Role drives whether background removal runs — the reason the enum is closed.
    func testSubjectLiftIsOffForWornAndTag() {
        XCTAssertTrue(GarmentPhotoRole.front.shouldLiftSubject)
        XCTAssertTrue(GarmentPhotoRole.back.shouldLiftSubject)
        XCTAssertTrue(GarmentPhotoRole.detail.shouldLiftSubject)
        XCTAssertFalse(GarmentPhotoRole.worn.shouldLiftSubject,
                       "lifting a worn shot would cut the person out")
        XCTAssertFalse(GarmentPhotoRole.tag.shouldLiftSubject,
                       "a care label has no subject to lift")
    }

    func testRoleRawsAreStableStorageKeys() {
        XCTAssertEqual(GarmentPhotoRole.allCases.map(\.rawValue),
                       ["front", "back", "worn", "tag", "detail"])
    }
}
