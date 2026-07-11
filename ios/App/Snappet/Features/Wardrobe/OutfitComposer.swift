import Foundation

/// A pure, platform-free mirror of a `WardrobeItem` plus its wear history — the only
/// shape the composer/coach/stats see. Views build these from SwiftData rows; tests
/// build them from literals.
struct GarmentProfile: Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var category: GarmentCategory
    var color: GarmentColorFamily
    var pattern: GarmentPattern = .solid
    var style: GarmentStyle
    /// Empty = all-season.
    var seasons: Set<GarmentSeason> = []
    var isFavorite: Bool = false
    var wearCount: Int = 0
    var lastWornAt: Date? = nil

    func wearable(in season: GarmentSeason) -> Bool {
        seasons.isEmpty || seasons.contains(season)
    }
}

/// What the user asked for. `seed` varies only on Shuffle so results are reproducible.
struct OutfitRequest: Sendable, Equatable {
    var occasion: OutfitOccasion
    var season: GarmentSeason
    var tempBand: TempBand
    var note: String = ""
    var buildAround: UUID? = nil
    var seed: UInt64 = 0
}

/// A composed outfit: ordered slots + human "why this works" lines. Pure value.
/// Hashable so the generator can drive `navigationDestination(item:)` with it.
struct ComposedOutfit: Sendable, Hashable {
    struct Slot: Sendable, Hashable {
        var role: GarmentCategory
        var itemID: UUID
    }
    var slots: [Slot]
    var rationale: [String]
    var score: Double

    func itemIDs() -> [UUID] { slots.map(\.itemID) }
}

/// A "For You" feed entry: a composed outfit plus the one-line reason the card leads with.
struct SuggestedOutfit: Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var reason: String
    var outfit: ComposedOutfit
}

/// The Wardrobe keystone (wardrobe prompt 01): deterministic, explainable outfit
/// assembly from OWNED items only. Greedy slot-fill, scored on four axes —
/// occasion-formality fit, color harmony against the pieces already picked,
/// season/temperature eligibility, and freshness (rarely-worn pieces get rotated in).
/// The optional Apple-Intelligence pass only rephrases rationale copy; it never picks
/// items — selection stays auditable and unit-tested.
enum OutfitComposer {

    // MARK: - Custom generation

    /// Compose one outfit for the request, or nil when the closet can't cover the base
    /// slots (needs a dress, or a top + bottom, plus shoes).
    static func compose(items: [GarmentProfile], request: OutfitRequest, now: Date = .now) -> ComposedOutfit? {
        let window = request.occasion.adjusted(for: request.note)
        let eligible = items.filter { $0.wearable(in: request.season) }
        guard !eligible.isEmpty else { return nil }
        var rng = SplitMix64(seed: request.seed &+ 0x9E3779B97F4A7C15)

        var picked: [ComposedOutfit.Slot] = []
        var pickedProfiles: [GarmentProfile] = []
        var rationale: [String] = []

        func candidates(for role: GarmentCategory) -> [GarmentProfile] {
            eligible.filter { item in
                item.category == role && !picked.contains { $0.itemID == item.id }
            }
        }

        func score(_ item: GarmentProfile) -> Double {
            var s = 0.0
            // Formality fit: inside the window is best; each notch outside costs heavily.
            let f = item.style.formality
            if window.contains(f) { s += 3 }
            else { s += 3 - Double(min(abs(f - window.lowerBound), abs(f - window.upperBound))) * 1.6 }
            // Harmony against everything already on the board.
            if !pickedProfiles.isEmpty {
                let h = pickedProfiles.map { GarmentColorFamily.harmony($0.color, item.color) }.reduce(0, +)
                    / Double(pickedProfiles.count)
                s += h * 2
            }
            // Freshness: rotate the closet — unworn/stale pieces get a bump.
            s += freshnessBonus(item, now: now)
            if item.isFavorite { s += 0.4 }
            // Two patterned pieces on one board is a beginner clash — charge for it.
            if item.pattern != .solid && pickedProfiles.contains(where: { $0.pattern != .solid }) { s -= 0.8 }
            // Seeded jitter so Shuffle re-ranks near-ties without destroying determinism.
            s += Double(rng.next() % 1000) / 1000 * 0.35
            return s
        }

        func fill(_ role: GarmentCategory) -> GarmentProfile? {
            guard let best = candidates(for: role).max(by: { score($0) < score($1) }) else { return nil }
            picked.append(.init(role: role, itemID: best.id))
            pickedProfiles.append(best)
            return best
        }

        // Anchor: the build-around item, if given, claims its slot first.
        var anchoredRole: GarmentCategory?
        if let anchorID = request.buildAround, let anchor = eligible.first(where: { $0.id == anchorID }) {
            picked.append(.init(role: anchor.category, itemID: anchor.id))
            pickedProfiles.append(anchor)
            anchoredRole = anchor.category
            rationale.append("Built around your \(anchor.name.lowercased()).")
        }

        // Base coverage: a dress, or top + bottom.
        let hasDress = anchoredRole == .dress
        let hasTop = anchoredRole == .top
        let hasBottom = anchoredRole == .bottom
        if !hasDress {
            let dressOption = candidates(for: .dress).max(by: { score($0) < score($1) })
            let topOption = candidates(for: .top).max(by: { score($0) < score($1) })
            // Prefer separates unless the closet only offers a dress (or the dress clearly wins
            // and nothing anchored the separates path).
            if !hasTop && !hasBottom, topOption == nil, let dress = dressOption {
                picked.append(.init(role: .dress, itemID: dress.id))
                pickedProfiles.append(dress)
            } else {
                if !hasTop { _ = fill(.top) }
                if !hasBottom { _ = fill(.bottom) }
            }
        }
        // A wearable outfit needs its base covered.
        let roles = Set(picked.map(\.role))
        guard roles.contains(.dress) || (roles.contains(.top) && roles.contains(.bottom)) else { return nil }

        _ = fill(.shoes)

        if request.tempBand.needsOuterLayer && anchoredRole != .outerwear {
            if let layer = fill(.outerwear) {
                rationale.append("\(layer.name) layers for the \(request.tempBand.title.lowercased()) weather.")
            }
        }

        // One favorite accessory, if it harmonizes.
        if let acc = candidates(for: .accessory).filter(\.isFavorite).max(by: { score($0) < score($1) }) {
            picked.append(.init(role: .accessory, itemID: acc.id))
            pickedProfiles.append(acc)
        }

        // Lead rationale lines.
        let baseNames = pickedProfiles.prefix(2).map { $0.name.lowercased() }.joined(separator: " + ")
        rationale.insert("\(baseNames.prefix(1).capitalized + baseNames.dropFirst()) fits \(request.occasion.title.lowercased()).", at: 0)
        if let stale = pickedProfiles.first(where: { freshnessBonus($0, now: now) >= 0.9 }) {
            rationale.append("Rotating in your \(stale.name.lowercased()) — it hasn't been worn in a while.")
        }

        let total = pickedProfiles.reduce(0.0) { acc, p in
            acc + (window.contains(p.style.formality) ? 1 : 0)
        } / Double(max(1, pickedProfiles.count))
        return ComposedOutfit(slots: picked, rationale: rationale, score: total)
    }

    /// Ranked alternatives for one slot of an existing outfit (the board's ⇄ swap).
    /// Excludes the items already on the board; best-first.
    static func alternatives(for role: GarmentCategory, in outfit: ComposedOutfit,
                             items: [GarmentProfile], request: OutfitRequest, now: Date = .now) -> [GarmentProfile] {
        let onBoard = Set(outfit.itemIDs())
        let window = request.occasion.adjusted(for: request.note)
        let others = items.filter {
            $0.category == role && !onBoard.contains($0.id) && $0.wearable(in: request.season)
        }
        let boardProfiles = items.filter { onBoard.contains($0.id) && $0.category != role }
        func score(_ item: GarmentProfile) -> Double {
            var s = window.contains(item.style.formality) ? 3.0 : 1.0
            if !boardProfiles.isEmpty {
                s += boardProfiles.map { GarmentColorFamily.harmony($0.color, item.color) }.reduce(0, +)
                    / Double(boardProfiles.count) * 2
            }
            s += freshnessBonus(item, now: now)
            return s
        }
        return others.sorted { score($0) > score($1) }
    }

    // MARK: - For You feed

    /// The daily suggestions: up to three outfits with distinct intents — rotate a stale
    /// piece, dress today's weather, celebrate a favorite. Deterministic for a given
    /// (items, date) so the feed doesn't reshuffle on every appearance.
    static func forYou(items: [GarmentProfile], date: Date = .now,
                       season: GarmentSeason? = nil, tempBand: TempBand? = nil,
                       calendar: Calendar = .current) -> [SuggestedOutfit] {
        let month = calendar.component(.month, from: date)
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let s = season ?? .forMonth(month)
        let band = tempBand ?? .forSeason(s)
        let daySeed = UInt64(day)

        var out: [SuggestedOutfit] = []
        var used = Set<UUID>()

        func add(_ title: String, _ reason: String, _ outfit: ComposedOutfit?) {
            guard let outfit else { return }
            // Feed variety: skip a suggestion whose base repeats an earlier card.
            let base = Set(outfit.slots.filter { $0.role == .top || $0.role == .bottom || $0.role == .dress }.map(\.itemID))
            guard base.isDisjoint(with: used) || out.isEmpty else { return }
            used.formUnion(base)
            out.append(SuggestedOutfit(title: title, reason: reason, outfit: outfit))
        }

        // 1 — rotation: build around the stalest wearable base piece.
        if let mostStale = items
            .filter({ ($0.category == .top || $0.category == .bottom || $0.category == .dress) && $0.wearable(in: s) })
            .max(by: { staleness($0, now: date) < staleness($1, now: date) })
        {
            let req = OutfitRequest(occasion: .work, season: s, tempBand: band, buildAround: mostStale.id, seed: daySeed)
            let reason = mostStale.wearCount == 0
                ? "Rotates in your \(mostStale.name.lowercased()) — never worn"
                : "Your \(mostStale.name.lowercased()) is overdue a wear"
            add("Office-ready", reason, compose(items: items, request: req, now: date))
        }

        // 2 — weather: a casual fit for today's band.
        let weatherReq = OutfitRequest(occasion: .casualWeekend, season: s, tempBand: band, seed: daySeed &+ 1)
        add("Easy \(band.needsOuterLayer ? "layers" : "fit")",
            "Good for \(band.title.lowercased()) \(s.title.lowercased()) weather",
            compose(items: items, request: weatherReq, now: date))

        // 3 — favorite: build around a loved piece.
        if let fav = items.filter({ $0.isFavorite && $0.wearable(in: s) })
            .max(by: { $0.wearCount < $1.wearCount }) {
            let req = OutfitRequest(occasion: .dateNight, season: s, tempBand: band, buildAround: fav.id, seed: daySeed &+ 2)
            add("Crowd favorite", "Around your ♥ \(fav.name.lowercased())", compose(items: items, request: req, now: date))
        }

        return out
    }

    // MARK: - Freshness

    /// 0…1: how overdue a wear this item is. Never-worn = 1; worn today = 0; ramps back
    /// up over 60 days.
    static func staleness(_ item: GarmentProfile, now: Date) -> Double {
        guard item.wearCount > 0, let last = item.lastWornAt else { return 1 }
        let days = max(0, now.timeIntervalSince(last) / 86_400)
        return min(1, days / 60)
    }

    private static func freshnessBonus(_ item: GarmentProfile, now: Date) -> Double {
        staleness(item, now: now)
    }
}

/// Tiny deterministic RNG (SplitMix64) — seeded per compose so Shuffle is reproducible
/// and tests are stable. Not for cryptography, obviously.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
