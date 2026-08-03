import XCTest
@testable import Snappet

/// The cleanup proposal for data already stored in the wrong fields (wardrobe prompt 05).
/// Fixtures are lifted verbatim from the real device closet — including the six values the plan
/// must REFUSE to classify.
final class WardrobeTidyPlanTests: XCTestCase {

    private func row(_ name: String, material: String = "", brand: String = "",
                     size: String = "") -> WardrobeTidyPlan.Row {
        WardrobeTidyPlan.Row(id: UUID(), name: name, material: material,
                             brand: brand, sizeLabel: size)
    }

    // MARK: material → brand

    func testKnownBrandsInMaterialBecomeBrandAndClearMaterial() {
        let r = row("Blue tank top", material: "Uniqlo")
        let plan = WardrobeTidyPlan.make(rows: [r])

        XCTAssertEqual(plan.edits.count, 2)
        XCTAssertTrue(plan.edits.contains(.init(itemID: r.id, field: .brand,
                                                oldValue: "Uniqlo", newValue: "Uniqlo")))
        XCTAssertTrue(plan.edits.contains(.init(itemID: r.id, field: .material,
                                                oldValue: "Uniqlo", newValue: "")),
                      "the value must be removed from material, not duplicated into both")
        XCTAssertTrue(plan.uncertain.isEmpty)
    }

    /// The whitespace split, exactly as it exists on device.
    func testWhitespaceVariantsMergeIntoOneBrandGroup() {
        let rows = Array(repeating: "Lululemon ", count: 25).map { row("Legging", material: $0) }
            + Array(repeating: "Lululemon", count: 5).map { row("Legging", material: $0) }
        let plan = WardrobeTidyPlan.make(rows: rows)

        XCTAssertEqual(plan.brandGroups.count, 1, "'Lululemon ' and 'Lululemon' are one brand")
        XCTAssertEqual(plan.brandGroups.first?.value, "Lululemon")
        XCTAssertEqual(plan.brandGroups.first?.count, 30)
        XCTAssertTrue(plan.edits.allSatisfy { $0.field != .brand || $0.newValue == "Lululemon" },
                      "every proposed brand value is normalized")
    }

    func testBrandGroupsAreRankedByItemCount() {
        let rows = Array(repeating: "Uniqlo", count: 32).map { row("Tee", material: $0) }
            + Array(repeating: "Temu", count: 10).map { row("Tee", material: $0) }
            + Array(repeating: "Lululemon", count: 30).map { row("Tee", material: $0) }
        let plan = WardrobeTidyPlan.make(rows: rows)
        XCTAssertEqual(plan.brandGroups.map(\.value), ["Uniqlo", "Lululemon", "Temu"])
    }

    /// A real fabric must be left exactly where it is — not moved, not questioned.
    func testActualFabricsStayInMaterial() {
        let plan = WardrobeTidyPlan.make(rows: [row("Flannel", material: "Cotton flannel")])
        XCTAssertTrue(plan.edits.isEmpty)
        XCTAssertTrue(plan.uncertain.isEmpty, "a fabric is not an open question")
    }

    func testAnItemThatAlreadyHasABrandIsLeftAlone() {
        let plan = WardrobeTidyPlan.make(rows: [row("Tee", material: "Uniqlo", brand: "Uniqlo")])
        XCTAssertTrue(plan.edits.isEmpty)
    }

    // MARK: the refusal — the point of the whole design

    /// These six are the actual values on the device. They are festival/anime PRINTS, and the plan
    /// must not silently write them into the brand vocabulary.
    func testPrintLikeValuesGoToUncertainRatherThanBeingGuessed() {
        let prints = ["Subtronics “BE NICE PLEASE”", "One piece zoro", "Illenium",
                      "Lollapalooza", "Insomniac camp edc", "Hello kitty"]
        let rows = prints.map { row("Graphic tee", material: $0) }
        let plan = WardrobeTidyPlan.make(rows: rows)

        XCTAssertEqual(plan.uncertain.count, 6)
        XCTAssertEqual(Set(plan.uncertain.map(\.value)), Set(prints))
        XCTAssertTrue(plan.edits.isEmpty, "nothing uncertain may appear as a confident edit")
    }

    func testUncertainValuesGroupTheirItems() {
        let a = row("Tee A", material: "Illenium")
        let b = row("Tee B", material: "illenium ")
        let plan = WardrobeTidyPlan.make(rows: [a, b])
        XCTAssertEqual(plan.uncertain.count, 1, "case/whitespace variants are one question")
        XCTAssertEqual(Set(plan.uncertain[0].itemIDs), Set([a.id, b.id]))
    }

    // MARK: size out of the name

    func testSizeIsLiftedOutOfTheNameAndTheNameIsCleaned() {
        let r = row("Black tank top size M")
        let plan = WardrobeTidyPlan.make(rows: [r])
        XCTAssertEqual(plan.sizeCount, 1)
        XCTAssertTrue(plan.edits.contains(.init(itemID: r.id, field: .sizeLabel,
                                                oldValue: "", newValue: "M")))
        XCTAssertTrue(plan.edits.contains(.init(itemID: r.id, field: .name,
                                                oldValue: r.name, newValue: "Black tank top")))
    }

    func testSizeExtractionIsConservative() {
        // No literal "size" word — must not guess.
        XCTAssertNil(WardrobeTidyPlan.sizeInName("Medium wash jeans"))
        XCTAssertNil(WardrobeTidyPlan.sizeInName("Black tank top"))
        // A long trailing token isn't a size.
        XCTAssertNil(WardrobeTidyPlan.sizeInName("Tee size enormous-custom"))
    }

    /// Stripping the size must never leave an item with a blank name.
    func testSizeExtractionRefusesToEmptyTheName() {
        XCTAssertNil(WardrobeTidyPlan.sizeInName("size M"))
    }

    func testSizeExtractionKeepsTextAfterTheSizeToken() {
        let out = WardrobeTidyPlan.sizeInName("Tank top size S blue")
        XCTAssertEqual(out?.size, "S")
        XCTAssertEqual(out?.cleanedName, "Tank top blue")
    }

    func testAnItemThatAlreadyHasASizeIsLeftAlone() {
        let plan = WardrobeTidyPlan.make(rows: [row("Tank top size M", size: "M")])
        XCTAssertEqual(plan.sizeCount, 0)
    }

    // MARK: the plan itself

    func testEmptyClosetProducesAnEmptyPlan() {
        XCTAssertTrue(WardrobeTidyPlan.make(rows: []).isEmpty)
    }

    func testPlanIsDeterministic() {
        let rows = [row("Tee size S", material: "Uniqlo"), row("Legging", material: "Lululemon ")]
        XCTAssertEqual(WardrobeTidyPlan.make(rows: rows), WardrobeTidyPlan.make(rows: rows))
    }

    /// A combined row proposes brand, material-clear, size and name — four edits, counted once.
    func testChangeCountReflectsEveryFieldTouched() {
        let plan = WardrobeTidyPlan.make(rows: [row("Black tank top size M", material: "Uniqlo")])
        XCTAssertEqual(plan.changeCount, 4)
        XCTAssertEqual(Set(plan.edits.map(\.field)), Set([.brand, .material, .sizeLabel, .name]))
    }
}
