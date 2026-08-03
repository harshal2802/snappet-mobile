import XCTest
@testable import Snappet

/// Normalization, dedupe and ordering for open dropdown vocabularies (wardrobe prompt 05).
/// The fixtures are the REAL shapes measured on the device closet, not invented ones.
final class WardrobeVocabularyRulesTests: XCTestCase {

    typealias Rules = WardrobeVocabularyRules

    // MARK: normalize

    /// The measured problem: 41 of 95 values carried stray whitespace, so `'Lululemon '`
    /// (25 items) and `'Lululemon'` (5 items) were two different brands.
    func testNormalizeTrimsTheWhitespaceThatSplitTheRealClosetsBrands() {
        XCTAssertEqual(Rules.normalize("Lululemon "), "Lululemon")
        XCTAssertEqual(Rules.normalize("  Uniqlo  "), "Uniqlo")
        XCTAssertEqual(Rules.normalize("Zara "), "Zara")
    }

    func testNormalizeCollapsesInnerWhitespace() {
        XCTAssertEqual(Rules.normalize("The  North   Face"), "The North Face")
        XCTAssertEqual(Rules.normalize("\tHot topic\n"), "Hot topic")
    }

    func testNormalizeOfBlankIsEmpty() {
        XCTAssertEqual(Rules.normalize("   "), "")
        XCTAssertEqual(Rules.normalize(""), "")
    }

    // MARK: sameness

    func testSamenessIgnoresWhitespaceAndCase() {
        XCTAssertTrue(Rules.isSameValue("Uniqlo ", "uniqlo"))
        XCTAssertTrue(Rules.isSameValue("  LULULEMON", "Lululemon"))
        XCTAssertFalse(Rules.isSameValue("Uniqlo", "Uniqlo Doremon"))
    }

    // MARK: fold

    /// Folding the real brand distribution must collapse the whitespace variants and rank by use.
    func testFoldMergesRealClosetBrandsAndRanksByCount() {
        let raw = Array(repeating: "Lululemon ", count: 25)
            + Array(repeating: "Lululemon", count: 5)
            + Array(repeating: "Uniqlo", count: 19)
            + Array(repeating: "Uniqlo ", count: 13)
            + Array(repeating: "Temu", count: 10)
        let folded = Rules.fold(raw)

        // Uniqlo 19 + 13 = 32 outranks Lululemon 25 + 5 = 30.
        XCTAssertEqual(folded.map(\.value), ["Uniqlo", "Lululemon", "Temu"])
        XCTAssertEqual(folded.map(\.count), [32, 30, 10])
    }

    /// The first spelling seen becomes the display form — folding must not impose a capitalization
    /// the user never typed.
    func testFoldKeepsTheFirstSpellingItSaw() {
        XCTAssertEqual(Rules.fold(["uniqlo", "Uniqlo", "UNIQLO"]).first?.value, "uniqlo")
        XCTAssertEqual(Rules.fold(["Uniqlo", "uniqlo"]).first?.value, "Uniqlo")
    }

    func testFoldDropsEmptiesAndBreaksTiesAlphabetically() {
        let folded = Rules.fold(["", "   ", "Nike", "Adidas"])
        XCTAssertEqual(folded.map(\.value), ["Adidas", "Nike"], "equal counts sort alphabetically")
    }

    // MARK: choices

    func testChoicesPutRememberedValuesFirstThenUnusedBuiltIns() {
        let choices = Rules.choices(
            field: .color,
            remembered: [("Mustard", "yellow", 3), ("Sage", "green", 7)],
            builtInTitles: [("black", "Black"), ("yellow", "Yellow")])

        XCTAssertEqual(choices.prefix(2).map(\.value), ["Sage", "Mustard"], "most used first")
        XCTAssertFalse(choices[0].isBuiltIn)
        XCTAssertTrue(choices.contains { $0.value == "Black" && $0.isBuiltIn })
    }

    /// A custom value that shadows a built-in must not produce two rows for the same thing.
    func testChoicesDoNotDuplicateABuiltInTheUserAlsoTyped() {
        let choices = Rules.choices(
            field: .color,
            remembered: [("black", "black", 4)],
            builtInTitles: [("black", "Black"), ("white", "White")])
        XCTAssertEqual(choices.filter { Rules.isSameValue($0.value, "black") }.count, 1)
    }

    // MARK: validation

    func testRejectsBlankTooLongAndDuplicateValues() {
        XCTAssertNotNil(Rules.rejectionReason(for: "  ", field: .brand, existing: []))
        XCTAssertNotNil(Rules.rejectionReason(for: String(repeating: "a", count: 41),
                                              field: .brand, existing: []))
        XCTAssertNotNil(Rules.rejectionReason(for: "Uniqlo ", field: .brand, existing: ["uniqlo"]),
                        "a whitespace/case variant of an existing value is a duplicate")
        XCTAssertNil(Rules.rejectionReason(for: "Arc'teryx", field: .brand, existing: ["Uniqlo"]))
    }

    // MARK: fields

    /// Only the fields the composer scores demand a "behaves like" answer.
    func testOnlyScoredFieldsNeedMapping() {
        XCTAssertTrue(Rules.Field.color.needsMapping)
        XCTAssertTrue(Rules.Field.category.needsMapping)
        XCTAssertTrue(Rules.Field.pattern.needsMapping)
        XCTAssertTrue(Rules.Field.style.needsMapping)
        XCTAssertFalse(Rules.Field.brand.needsMapping)
        XCTAssertFalse(Rules.Field.size.needsMapping)
        XCTAssertFalse(Rules.Field.material.needsMapping)
    }

    func testScoredFieldsOfferTheirBuiltInsAndUnscoredOfferNone() {
        XCTAssertEqual(Rules.Field.color.builtInRaws.count, GarmentColorFamily.allCases.count)
        XCTAssertTrue(Rules.Field.brand.builtInRaws.isEmpty)
    }
}
