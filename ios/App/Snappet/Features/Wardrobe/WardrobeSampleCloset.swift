import Foundation
import SwiftData

/// The demo/UITest closet: ~12 pieces across every slot so For You, the generator, and
/// the coach all have something to chew on with zero Photos dependency (items render
/// their category-emoji placeholder tile — the same Kilter-fixture trick). Reachable
/// from the empty state ("Try a sample closet") and deletable like any real item.
enum WardrobeSampleCloset {

    /// Insert the sample items + a light wear history. No-op when the closet already
    /// has items (never pollutes a real wardrobe).
    @MainActor
    static func seed(into context: ModelContext, now: Date = .now) {
        let existing = (try? context.fetchCount(FetchDescriptor<WardrobeItem>())) ?? 0
        guard existing == 0 else { return }

        func days(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

        // Inserted imperatively, one item per statement — a 13-element array literal of
        // (WardrobeItem, [Int]) tuples blows the expression type-checker budget (the
        // SnappetBackup.recordCount lesson).
        func add(_ item: WardrobeItem, wears: [Int]) {
            context.insert(item)
            for d in wears { context.insert(WearEvent(itemID: item.id, wornOn: days(d))) }
        }

        add(WardrobeItem(name: "Navy flannel shirt", category: .top, color: .navy, pattern: .plaid,
                         style: .casual, material: "Cotton flannel", seasons: [.fall, .winter],
                         cost: 49, isFavorite: true, createdAt: days(120)), wears: [3, 11, 25, 40])
        add(WardrobeItem(name: "White oxford", category: .top, color: .white,
                         style: .smartCasual, material: "Cotton", cost: 65, createdAt: days(130)), wears: [])
        add(WardrobeItem(name: "Grey tee", category: .top, color: .grey,
                         style: .casual, material: "Cotton", cost: 19, createdAt: days(90)), wears: [2, 9, 16])
        add(WardrobeItem(name: "Black turtleneck", category: .top, color: .black,
                         style: .smartCasual, material: "Merino", seasons: [.fall, .winter],
                         cost: 80, createdAt: days(200)), wears: [30])
        add(WardrobeItem(name: "Brown chinos", category: .bottom, color: .brown,
                         style: .smartCasual, material: "Twill", cost: 58, createdAt: days(110)), wears: [3, 20, 34])
        add(WardrobeItem(name: "Dark jeans", category: .bottom, color: .denim,
                         style: .casual, material: "Denim", cost: 70, createdAt: days(300)), wears: [5, 12, 19, 26, 41])
        add(WardrobeItem(name: "Grey joggers", category: .bottom, color: .grey,
                         style: .athletic, material: "Fleece", cost: 35, createdAt: days(80)), wears: [1, 8])
        add(WardrobeItem(name: "Tan jacket", category: .outerwear, color: .tan,
                         style: .smartCasual, material: "Cotton canvas", seasons: [.fall, .spring],
                         cost: 120, isFavorite: true, createdAt: days(140)), wears: [11, 33])
        add(WardrobeItem(name: "Black overcoat", category: .outerwear, color: .black,
                         style: .business, material: "Wool", seasons: [.winter],
                         cost: 210, createdAt: days(400)), wears: [45])
        add(WardrobeItem(name: "White sneakers", category: .shoes, color: .white,
                         style: .casual, material: "Leather", cost: 90, createdAt: days(150)), wears: [2, 9, 20, 33])
        add(WardrobeItem(name: "Brown loafers", category: .shoes, color: .brown,
                         style: .business, material: "Suede", cost: 110, createdAt: days(220)), wears: [34])
        add(WardrobeItem(name: "Green beanie", category: .headwear, color: .green,
                         style: .casual, material: "Wool", seasons: [.winter], cost: 18, createdAt: days(100)), wears: [])
        add(WardrobeItem(name: "Burgundy scarf", category: .accessory, color: .burgundy,
                         style: .smartCasual, material: "Wool", seasons: [.fall, .winter],
                         cost: 25, isFavorite: true, createdAt: days(160)), wears: [40])
        try? context.save()
    }
}
