import Foundation

/// Pure wear-log arithmetic: cost-per-wear, staleness labels, per-item aggregation.
/// Fed by `WearEvent` rows; owns every formatting rule so the item card, the detail
/// stats, and the closet nudge pill all agree.
enum WearStats {

    /// Aggregate wear info for one item.
    struct ItemStats: Sendable, Equatable {
        var wearCount: Int = 0
        var lastWornAt: Date? = nil
        var costPerWear: Double? = nil
    }

    /// Fold a wear log into per-item stats. `costs` maps itemID → purchase cost (optional).
    static func byItem(wornItemIDs: [(itemID: UUID, wornOn: Date)],
                       costs: [UUID: Double] = [:]) -> [UUID: ItemStats] {
        var out: [UUID: ItemStats] = [:]
        for (id, day) in wornItemIDs {
            var s = out[id] ?? ItemStats()
            s.wearCount += 1
            if s.lastWornAt.map({ day > $0 }) ?? true { s.lastWornAt = day }
            out[id] = s
        }
        for (id, cost) in costs {
            var s = out[id] ?? ItemStats()
            s.costPerWear = costPerWear(cost: cost, wears: s.wearCount)
            out[id] = s
        }
        return out
    }

    /// Cost per wear; a never-worn item shows its full cost (the honest number).
    static func costPerWear(cost: Double, wears: Int) -> Double {
        wears <= 0 ? cost : cost / Double(wears)
    }

    /// Rarely-worn nudge: never worn, or last worn more than `staleDays` ago.
    static func isRarelyWorn(wearCount: Int, lastWornAt: Date?, now: Date, staleDays: Int = 90) -> Bool {
        guard wearCount > 0, let last = lastWornAt else { return true }
        return now.timeIntervalSince(last) > Double(staleDays) * 86_400
    }

    /// The wear pill label: "12×", or "0× · 4 mo" for a stale piece (age since added).
    static func pillLabel(wearCount: Int, lastWornAt: Date?, addedAt: Date, now: Date) -> String {
        if wearCount == 0 {
            let months = Int(now.timeIntervalSince(addedAt) / (30 * 86_400))
            return months >= 1 ? "0× · \(months) mo" : "0×"
        }
        return "\(wearCount)×"
    }

    /// The user's currency code, for every price the module renders. One source so the detail
    /// line, the purchase card and cost-per-wear can't disagree; USD only as the last resort
    /// (a locale with no currency). Tests pass an explicit code and never read this.
    static var localCurrencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    /// "$4.08" style cost-per-wear string (system currency formatting, no cents games).
    static func costPerWearLabel(cost: Double?, wears: Int,
                                 currencyCode: String = localCurrencyCode) -> String? {
        guard let cost else { return nil }
        let v = costPerWear(cost: cost, wears: wears)
        return v.formatted(.currency(code: currencyCode).precision(.fractionLength(2)))
    }
}
