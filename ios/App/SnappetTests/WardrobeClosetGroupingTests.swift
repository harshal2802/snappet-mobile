import XCTest
@testable import Snappet

/// Closet grouping and quick-filter chips once categories can be CUSTOM (wardrobe prompt 05
/// follow-up). Pinned because the shipped bug was invisible in every test: the write path stored a
/// custom category fine, and the read path silently folded it into a built-in.
final class WardrobeClosetGroupingTests: XCTestCase {

    typealias Grouping = WardrobeClosetGrouping

    // MARK: titles

    func testBuiltInKeysRenderTheirTitles() {
        XCTAssertEqual(Grouping.title(forKey: "top", plural: true), "Tops")
        XCTAssertEqual(Grouping.title(forKey: "top", plural: false), "Top")
        XCTAssertEqual(Grouping.title(forKey: "accessory", plural: true), "Accessories")
    }

    /// A custom category is the user's own words — and must NOT be pluralized, because guessing an
    /// English plural for an arbitrary string produces "Loungewears".
    func testCustomKeysRenderVerbatimAndAreNeverPluralized() {
        XCTAssertEqual(Grouping.title(forKey: "Loungewear", plural: true), "Loungewear")
        XCTAssertEqual(Grouping.title(forKey: "Loungewear", plural: false), "Loungewear")
        XCTAssertEqual(Grouping.title(forKey: "Sari", plural: true), "Sari")
    }

    // MARK: present

    func testBuiltInsKeepEnumOrderAndCustomsFollowAlphabetically() {
        let present = Grouping.present(
            in: ["Loungewear", "bottom", "Activewear", "top", "bottom"], plural: true)
        XCTAssertEqual(present.map(\.title), ["Tops", "Bottoms", "Activewear", "Loungewear"])
    }

    func testPresentDeduplicatesAndSkipsEmptyKeys() {
        let present = Grouping.present(in: ["top", "top", "", "top"], plural: true)
        XCTAssertEqual(present.count, 1)
        XCTAssertEqual(present[0].key, "top")
    }

    func testPresentFlagsWhichAreBuiltIn() {
        let present = Grouping.present(in: ["top", "Loungewear"], plural: true)
        XCTAssertEqual(present.first { $0.key == "top" }?.isBuiltIn, true)
        XCTAssertEqual(present.first { $0.key == "Loungewear" }?.isBuiltIn, false)
    }

    // MARK: filter chips — the reported bug

    /// The bug as reported: "if i define a custom category it does not show those category on
    /// quick select filter".
    func testACustomCategoryInTheClosetGetsAFilterChip() {
        let chips = Grouping.filterChips(presentKeys: ["top", "Loungewear"])
        XCTAssertTrue(chips.contains { $0.key == "Loungewear" },
                      "a custom category present in the closet must be quick-selectable")
    }

    /// The six pinned built-ins are wayfinding, not a census — they show even for an empty closet.
    func testPinnedBuiltInsAppearEvenWhenTheClosetHasNone() {
        let chips = Grouping.filterChips(presentKeys: [])
        XCTAssertEqual(chips.map(\.key), ["top", "bottom", "shoes", "outerwear", "dress", "accessory"])
    }

    /// A custom chip that matched nothing would be noise, so customs are present-only.
    func testCustomChipsAreOnlyOfferedWhenSomethingUsesThem() {
        XCTAssertFalse(Grouping.filterChips(presentKeys: ["top"]).contains { !$0.isBuiltIn })
    }

    func testPinnedBuiltInsAreNotDuplicatedWhenAlsoPresent() {
        let chips = Grouping.filterChips(presentKeys: ["top", "top", "bottom"])
        XCTAssertEqual(chips.filter { $0.key == "top" }.count, 1)
    }

    /// A non-pinned built-in that IS in the closet (headwear, bag) still deserves a chip.
    func testNonPinnedBuiltInsAppearWhenPresent() {
        let chips = Grouping.filterChips(presentKeys: ["bag", "headwear"])
        XCTAssertTrue(chips.contains { $0.key == "bag" })
        XCTAssertTrue(chips.contains { $0.key == "headwear" })
    }

    /// Chip keys must be unique or `ForEach(id:)` collapses rows.
    func testChipKeysAreUnique() {
        let chips = Grouping.filterChips(presentKeys: ["top", "bag", "Loungewear", "bag"])
        XCTAssertEqual(Set(chips.map(\.key)).count, chips.count)
    }
}
