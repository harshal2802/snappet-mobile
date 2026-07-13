import XCTest
@testable import Snappet

/// The tag vocabulary's pure mappings: Vision label → category, RGB → color family,
/// style inference, wear stats. All device-free.
final class WardrobeTagsTests: XCTestCase {

    // MARK: - Vision label → category

    func testLabelMapping() {
        XCTAssertEqual(GarmentCategory.fromVisionLabel("jersey"), .top)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("T-shirt"), .top)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("blue jean"), .bottom)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("running shoe"), .shoes)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("trench coat"), .outerwear)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("cowboy hat"), .headwear)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("backpack"), .bag)
        XCTAssertEqual(GarmentCategory.fromVisionLabel("gown"), .dress)
        XCTAssertNil(GarmentCategory.fromVisionLabel("golden retriever"))
    }

    func testMoreSpecificOuterwearWinsOverGenericTop() {
        // "leather jacket" contains neither shirt-words first — outerwear is checked first.
        XCTAssertEqual(GarmentCategory.fromVisionLabel("leather jacket"), .outerwear)
    }

    // MARK: - RGB → color family

    func testAchromaticLadder() {
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.05, green: 0.05, blue: 0.06), .black)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.5, green: 0.5, blue: 0.52), .grey)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.97, green: 0.97, blue: 0.97), .white)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.93, green: 0.9, blue: 0.85), .cream)
    }

    func testChromaticFamilies() {
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.8, green: 0.1, blue: 0.12), .red)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.1, green: 0.12, blue: 0.28), .navy)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.2, green: 0.35, blue: 0.9), .blue)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.15, green: 0.6, blue: 0.2), .green)
        XCTAssertEqual(GarmentColorFamily.fromRGB(red: 0.45, green: 0.25, blue: 0.1), .brown)
    }

    // MARK: - Harmony

    func testNeutralsPairWithEverything() {
        for family in GarmentColorFamily.allCases {
            XCTAssertEqual(GarmentColorFamily.harmony(.navy, family), 1.0,
                           "navy is neutral; harmony with \(family) should be 1")
        }
    }

    func testClashScoresLow() {
        XCTAssertLessThan(GarmentColorFamily.harmony(.red, .green), 0.5)
    }

    func testAnalogousScoresWell() {
        XCTAssertGreaterThanOrEqual(GarmentColorFamily.harmony(.red, .orange), 0.8)
    }

    // MARK: - Style inference

    func testStyleInference() {
        XCTAssertEqual(GarmentStyle.inferred(from: "wool blazer"), .business)
        XCTAssertEqual(GarmentStyle.inferred(from: "oxford shirt"), .smartCasual)
        XCTAssertEqual(GarmentStyle.inferred(from: "running jersey"), .athletic)
        XCTAssertEqual(GarmentStyle.inferred(from: "plain tee"), .casual)
    }

    // MARK: - Season / temp defaults

    func testSeasonForMonth() {
        XCTAssertEqual(GarmentSeason.forMonth(1), .winter)
        XCTAssertEqual(GarmentSeason.forMonth(4), .spring)
        XCTAssertEqual(GarmentSeason.forMonth(7), .summer)
        XCTAssertEqual(GarmentSeason.forMonth(10), .fall)
    }

    func testOuterLayerBands() {
        XCTAssertTrue(TempBand.cold.needsOuterLayer)
        XCTAssertTrue(TempBand.cool.needsOuterLayer)
        XCTAssertFalse(TempBand.hot.needsOuterLayer)
    }

    // MARK: - WearStats

    func testCostPerWear() {
        XCTAssertEqual(WearStats.costPerWear(cost: 49, wears: 12), 49.0 / 12, accuracy: 0.001)
        XCTAssertEqual(WearStats.costPerWear(cost: 49, wears: 0), 49, "never worn shows full cost")
    }

    func testByItemAggregation() {
        let a = UUID(), b = UUID()
        let now = Date()
        let stats = WearStats.byItem(
            wornItemIDs: [(a, now.addingTimeInterval(-86_400)), (a, now), (b, now)],
            costs: [a: 60])
        XCTAssertEqual(stats[a]?.wearCount, 2)
        XCTAssertEqual(stats[a]?.lastWornAt, now)
        XCTAssertEqual(stats[a]?.costPerWear ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(stats[b]?.wearCount, 1)
        XCTAssertNil(stats[b]?.costPerWear)
    }

    func testRarelyWorn() {
        let now = Date()
        XCTAssertTrue(WearStats.isRarelyWorn(wearCount: 0, lastWornAt: nil, now: now))
        XCTAssertTrue(WearStats.isRarelyWorn(wearCount: 3,
                                             lastWornAt: now.addingTimeInterval(-100 * 86_400), now: now))
        XCTAssertFalse(WearStats.isRarelyWorn(wearCount: 3,
                                              lastWornAt: now.addingTimeInterval(-5 * 86_400), now: now))
    }

    func testPillLabels() {
        let now = Date()
        XCTAssertEqual(WearStats.pillLabel(wearCount: 12, lastWornAt: now, addedAt: now, now: now), "12×")
        XCTAssertEqual(WearStats.pillLabel(wearCount: 0, lastWornAt: nil,
                                           addedAt: now.addingTimeInterval(-130 * 86_400), now: now), "0× · 4 mo")
        XCTAssertEqual(WearStats.pillLabel(wearCount: 0, lastWornAt: nil, addedAt: now, now: now), "0×")
    }

    // MARK: - Coach heuristic floor

    func testHeuristicCoachCitesOwnedItems() {
        let shirt = GarmentProfile(id: UUID(), name: "Navy flannel shirt", category: .top,
                                   color: .navy, style: .casual)
        let chinos = GarmentProfile(id: UUID(), name: "Brown chinos", category: .bottom,
                                    color: .brown, style: .smartCasual)
        let shoes = GarmentProfile(id: UUID(), name: "White sneakers", category: .shoes,
                                   color: .white, style: .casual)
        let closet = [shirt, chinos, shoes]
        let answer = WardrobeIntelligence.heuristicAnswer(
            question: "What goes with this?", item: shirt, closet: closet,
            season: .fall, tempBand: .mild)
        XCTAssertFalse(answer.fromAI)
        XCTAssertFalse(answer.text.isEmpty)
        let owned = Set(closet.map(\.id))
        XCTAssertTrue(answer.suggestedItemIDs.allSatisfy { owned.contains($0) })
        XCTAssertFalse(answer.suggestedItemIDs.contains(shirt.id), "shouldn't recommend the item to itself")
    }

    func testHeuristicCoachBusinessCasualVerdict() {
        let blazer = GarmentProfile(id: UUID(), name: "Navy blazer", category: .outerwear,
                                    color: .navy, style: .business)
        let answer = WardrobeIntelligence.heuristicAnswer(
            question: "Is this business casual?", item: blazer, closet: [blazer],
            season: .fall, tempBand: .mild)
        XCTAssertTrue(answer.text.lowercased().contains("yes"))
    }
}
