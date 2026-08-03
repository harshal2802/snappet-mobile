import XCTest
@testable import Snappet

/// The tidy plan against the EXACT `material` distribution measured on the device closet
/// (wardrobe prompt 05). Not a representative sample — every value and count below was read out
/// of MrRobot's store, so this test is what stops the allow-list silently regressing on the one
/// closet that actually matters.
///
/// Re-derive with:
/// ```sh
/// sqlite3 default.store "select trim(ZMATERIAL), count(*) from ZWARDROBEITEM \
///   where trim(ZMATERIAL)!='' group by lower(trim(ZMATERIAL)) order by 2 desc;"
/// ```
final class WardrobeTidyRealClosetTests: XCTestCase {

    /// value → item count, verbatim from the device.
    private let realMaterials: [(String, Int)] = [
        ("Uniqlo", 32), ("Lululemon", 30), ("Temu", 10), ("Amazon", 5),
        ("Zara", 2), ("Nike", 2), ("Adidas", 2),
        ("WEI-TEX", 1), ("Uniqlo doremon", 1), ("Subtronics “BE NICE PLEASE”", 1),
        ("One piece zoro", 1), ("One piece", 1), ("Lollapalooza", 1), ("Kalenji", 1),
        ("Insomniac camp edc", 1), ("Illenium", 1), ("Hot topic", 1),
        ("Hello kitty", 1), ("Google", 1),
    ]

    private func realRows() -> [WardrobeTidyPlan.Row] {
        realMaterials.flatMap { value, count in
            (0..<count).map { _ in
                WardrobeTidyPlan.Row(id: UUID(), name: "Garment", material: value)
            }
        }
    }

    /// The retailers must all be recognised — including the long tail, which is where an
    /// allow-list quietly rots.
    func testEveryRealRetailerIsClassifiedAsABrand() {
        let plan = WardrobeTidyPlan.make(rows: realRows())
        let brands = Set(plan.brandGroups.map { $0.value.lowercased() })

        for expected in ["uniqlo", "lululemon", "temu", "amazon", "zara", "nike", "adidas",
                         "wei-tex", "kalenji", "google", "hot topic"] {
            XCTAssertTrue(brands.contains(expected),
                          "\(expected) is a real retailer in the closet and must be a brand")
        }
    }

    /// The prints must NOT be guessed at. These are festival line-ups, anime and a licensed
    /// character — writing any of them into the brand vocabulary would pollute it permanently.
    func testEveryRealPrintIsLeftUncertain() {
        let plan = WardrobeTidyPlan.make(rows: realRows())
        let uncertain = Set(plan.uncertain.map { $0.value.lowercased() })

        for print in ["subtronics “be nice please”", "one piece zoro", "one piece",
                      "lollapalooza", "insomniac camp edc", "illenium", "hello kitty"] {
            XCTAssertTrue(uncertain.contains(print),
                          "\(print) is a print, not a brand — it must be asked about, not assumed")
        }
    }

    /// "Uniqlo doremon" is a Uniqlo × Doraemon collab: a retailer AND a print in one string.
    /// Exactly the case the plan must refuse rather than half-match on the "uniqlo" prefix.
    func testACollabValueIsNotSilentlyMatchedOnItsBrandPrefix() {
        let plan = WardrobeTidyPlan.make(rows: realRows())
        XCTAssertTrue(plan.uncertain.contains { $0.value == "Uniqlo doremon" },
                      "a brand+print collab must be asked about, not folded into the brand")
        XCTAssertFalse(plan.brandGroups.contains { $0.value == "Uniqlo doremon" })
    }

    /// The headline numbers, so a change in classification shows up as a diff rather than a vibe.
    func testTheRealClosetSplitsIntoTheExpectedBuckets() {
        let plan = WardrobeTidyPlan.make(rows: realRows())

        XCTAssertEqual(plan.brandGroups.count, 11, "11 distinct retailers")
        // 83 from the multi-item retailers + WEI-TEX, Kalenji, Hot topic and Google.
        XCTAssertEqual(plan.brandGroups.reduce(0) { $0 + $1.count }, 87,
                       "87 of the 95 material values are confidently brands")
        XCTAssertEqual(plan.uncertain.count, 8, "8 values need a human answer")

        // Ranking drives the review screen's ordering.
        XCTAssertEqual(plan.brandGroups.prefix(4).map(\.value),
                       ["Uniqlo", "Lululemon", "Temu", "Amazon"])
    }

    /// Nothing uncertain may also appear as a confident edit — the two buckets must be disjoint,
    /// or a value would be both asked about and silently written.
    func testConfidentAndUncertainBucketsAreDisjoint() {
        let plan = WardrobeTidyPlan.make(rows: realRows())
        let uncertainItems = Set(plan.uncertain.flatMap(\.itemIDs))
        let editedItems = Set(plan.edits.map(\.itemID))
        XCTAssertTrue(uncertainItems.isDisjoint(with: editedItems))
    }
}
