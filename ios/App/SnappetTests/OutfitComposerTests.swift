import XCTest
@testable import Snappet

/// The Wardrobe keystone under test: pure composition — no store, no device.
final class OutfitComposerTests: XCTestCase {

    // MARK: - Fixtures

    private func closet(now: Date = .now) -> [GarmentProfile] {
        [
            GarmentProfile(id: id(1), name: "White oxford", category: .top, color: .white,
                           style: .smartCasual),
            GarmentProfile(id: id(2), name: "Grey tee", category: .top, color: .grey,
                           style: .casual, wearCount: 9, lastWornAt: now.addingTimeInterval(-2 * 86_400)),
            GarmentProfile(id: id(3), name: "Brown chinos", category: .bottom, color: .brown,
                           style: .smartCasual, wearCount: 4, lastWornAt: now.addingTimeInterval(-5 * 86_400)),
            GarmentProfile(id: id(4), name: "Grey joggers", category: .bottom, color: .grey,
                           style: .athletic, wearCount: 6, lastWornAt: now.addingTimeInterval(-86_400)),
            GarmentProfile(id: id(5), name: "Brown loafers", category: .shoes, color: .brown,
                           style: .business, wearCount: 2, lastWornAt: now.addingTimeInterval(-30 * 86_400)),
            GarmentProfile(id: id(6), name: "White sneakers", category: .shoes, color: .white,
                           style: .casual, wearCount: 12, lastWornAt: now.addingTimeInterval(-86_400)),
            GarmentProfile(id: id(7), name: "Tan jacket", category: .outerwear, color: .tan,
                           style: .smartCasual, seasons: [.fall, .spring]),
            GarmentProfile(id: id(8), name: "Summer shorts", category: .bottom, color: .blue,
                           style: .casual, seasons: [.summer]),
        ]
    }

    private func id(_ n: UInt8) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private func request(_ occasion: OutfitOccasion = .work,
                         season: GarmentSeason = .fall,
                         band: TempBand = .cool,
                         note: String = "",
                         buildAround: UUID? = nil,
                         seed: UInt64 = 0) -> OutfitRequest {
        OutfitRequest(occasion: occasion, season: season, tempBand: band,
                      note: note, buildAround: buildAround, seed: seed)
    }

    // MARK: - Base coverage

    func testComposesTopBottomShoes() {
        let outfit = OutfitComposer.compose(items: closet(), request: request())
        let roles = Set(outfit?.slots.map(\.role) ?? [])
        XCTAssertTrue(roles.contains(.top))
        XCTAssertTrue(roles.contains(.bottom))
        XCTAssertTrue(roles.contains(.shoes))
    }

    func testUsesOnlyOwnedItems() {
        let items = closet()
        let owned = Set(items.map(\.id))
        let outfit = OutfitComposer.compose(items: items, request: request())
        XCTAssertNotNil(outfit)
        for slot in outfit!.slots {
            XCTAssertTrue(owned.contains(slot.itemID), "composer invented an item")
        }
    }

    func testReturnsNilWhenBaseImpossible() {
        // Only shoes — no top/bottom/dress can cover the base.
        let shoesOnly = closet().filter { $0.category == .shoes }
        XCTAssertNil(OutfitComposer.compose(items: shoesOnly, request: request()))
    }

    func testNoDuplicateItemsInOneOutfit() {
        let outfit = OutfitComposer.compose(items: closet(), request: request())
        let ids = outfit?.itemIDs() ?? []
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - Occasion / formality

    func testWorkPrefersSmartPiecesOverAthletic() {
        let outfit = OutfitComposer.compose(items: closet(), request: request(.work))
        let bottom = outfit?.slots.first { $0.role == .bottom }
        XCTAssertEqual(bottom?.itemID, id(3), "work should pick chinos, not joggers")
    }

    func testCasualWeekendAllowsCasualPieces() {
        let outfit = OutfitComposer.compose(items: closet(), request: request(.casualWeekend))
        XCTAssertNotNil(outfit)
        // Whatever it picks, the outfit's slots come from the eligible-season pool.
        XCTAssertFalse(outfit!.slots.contains { $0.itemID == id(8) }, "summer shorts are out of season in fall")
    }

    func testNoteNudgesFormalityWindow() {
        let base = OutfitOccasion.casualWeekend.adjusted(for: "")
        let up = OutfitOccasion.casualWeekend.adjusted(for: "client meeting downtown")
        XCTAssertGreaterThan(up.lowerBound, base.lowerBound - 1)
        XCTAssertEqual(up.upperBound, min(5, base.upperBound + 1))
    }

    // MARK: - Weather

    func testCoolWeatherAddsOuterLayer() {
        let outfit = OutfitComposer.compose(items: closet(), request: request(band: .cool))
        XCTAssertTrue(outfit?.slots.contains { $0.role == .outerwear } ?? false)
    }

    func testHotWeatherSkipsOuterLayer() {
        let outfit = OutfitComposer.compose(items: closet(), request: request(season: .summer, band: .hot))
        XCTAssertFalse(outfit?.slots.contains { $0.role == .outerwear } ?? true)
    }

    func testSeasonFiltersItems() {
        // In summer, the fall/spring-only tan jacket must never appear.
        let outfit = OutfitComposer.compose(items: closet(), request: request(season: .summer, band: .cool))
        XCTAssertFalse(outfit?.slots.contains { $0.itemID == id(7) } ?? true)
    }

    // MARK: - Build-around & shuffle

    func testBuildAroundAnchorsTheItem() {
        let outfit = OutfitComposer.compose(items: closet(), request: request(buildAround: id(2)))
        XCTAssertTrue(outfit?.slots.contains { $0.itemID == id(2) } ?? false)
    }

    func testDeterministicForSameSeed() {
        let a = OutfitComposer.compose(items: closet(), request: request(seed: 7))
        let b = OutfitComposer.compose(items: closet(), request: request(seed: 7))
        XCTAssertEqual(a, b)
    }

    func testAlternativesExcludeBoardItems() {
        let items = closet()
        let outfit = OutfitComposer.compose(items: items, request: request())!
        let alts = OutfitComposer.alternatives(for: .shoes, in: outfit, items: items, request: request())
        let onBoard = Set(outfit.itemIDs())
        XCTAssertFalse(alts.contains { onBoard.contains($0.id) })
        XCTAssertTrue(alts.allSatisfy { $0.category == .shoes })
    }

    // MARK: - For You

    func testForYouProducesSuggestionsWithReasons() {
        let suggestions = OutfitComposer.forYou(items: closet(), season: .fall, tempBand: .cool)
        XCTAssertFalse(suggestions.isEmpty)
        for s in suggestions {
            XCTAssertFalse(s.title.isEmpty)
            XCTAssertFalse(s.reason.isEmpty)
            XCTAssertFalse(s.outfit.slots.isEmpty)
        }
    }

    func testForYouRotationTargetsStalestPiece() {
        // The never-worn white oxford is the stalest base piece → the rotation card
        // must include it.
        let suggestions = OutfitComposer.forYou(items: closet(), season: .fall, tempBand: .cool)
        guard let rotation = suggestions.first else { return XCTFail("no suggestions") }
        XCTAssertTrue(rotation.outfit.slots.contains { $0.itemID == id(1) },
                      "rotation should build around the never-worn oxford")
        XCTAssertTrue(rotation.reason.lowercased().contains("never worn"))
    }

    func testForYouIsDeterministicPerDay() {
        let day = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let a = OutfitComposer.forYou(items: closet(now: day), date: day, season: .fall, tempBand: .cool)
        let b = OutfitComposer.forYou(items: closet(now: day), date: day, season: .fall, tempBand: .cool)
        XCTAssertEqual(a.map(\.outfit), b.map(\.outfit))
    }

    // MARK: - Staleness

    func testStalenessNeverWornIsMax() {
        let item = GarmentProfile(id: id(9), name: "New", category: .top, color: .white, style: .casual)
        XCTAssertEqual(OutfitComposer.staleness(item, now: .now), 1)
    }

    func testStalenessWornTodayIsZero() {
        let item = GarmentProfile(id: id(9), name: "Fresh", category: .top, color: .white,
                                  style: .casual, wearCount: 1, lastWornAt: .now)
        XCTAssertEqual(OutfitComposer.staleness(item, now: .now), 0, accuracy: 0.01)
    }
}
