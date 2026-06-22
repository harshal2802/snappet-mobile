import Foundation

// MARK: - Recap Feed — pure freshness helpers (F1)
//
// The "N new" diff + load state. Kept pure so the pill logic is unit-tested without UI.

enum FeedFreshness {
    enum LoadState: Equatable { case loading, loaded, empty }

    /// How many cards at the TOP are new vs a previously-seen snapshot. Counts leading current cards
    /// whose id wasn't already seen, stopping at the first already-seen id (a contiguous fresh run).
    static func newCount(current: [FeedCard], seen: Set<String>) -> Int {
        guard !seen.isEmpty else { return 0 }
        var n = 0
        for c in current {
            if seen.contains(c.id) { break }
            n += 1
        }
        return n
    }

    /// A snapshot of the top ids, stored when the user leaves so we can diff on return.
    static func topIDs(_ cards: [FeedCard], limit: Int = 80) -> Set<String> {
        Set(cards.prefix(limit).map(\.id))
    }

    /// The pill copy for `n` fresh cards (nil → no pill).
    static func pillText(newCount n: Int) -> String? {
        switch n {
        case ..<1: return nil
        case 1: return "1 new · tap to refresh"
        default: return "\(n) new · tap to refresh"
        }
    }
}
