import Foundation

// MARK: - Recap Feed — pure keyset pagination (F1)
//
// Pages over the composer's pre-ordered cards using an (anchorDate, id) cursor. Because the
// composer's order is total + stable, paging never duplicates or skips across page boundaries.

enum FeedPagination {
    struct Cursor: Equatable, Sendable {
        var anchorDate: Date
        var id: String
    }

    /// One keyset page after `cursor` (nil = from the top). Returns the slice + the next cursor (nil at end).
    static func page(_ cards: [FeedCard], after cursor: Cursor?, limit: Int) -> (page: [FeedCard], next: Cursor?) {
        guard limit > 0 else { return ([], nil) }
        let start: Int
        if let cursor, let idx = cards.firstIndex(where: { $0.id == cursor.id && $0.anchorDate == cursor.anchorDate }) {
            start = idx + 1
        } else {
            start = 0
        }
        guard start < cards.count else { return ([], nil) }
        let end = min(start + limit, cards.count)
        let slice = Array(cards[start..<end])
        let next = end < cards.count ? slice.last.map { Cursor(anchorDate: $0.anchorDate, id: $0.id) } : nil
        return (slice, next)
    }

    /// The leading window of `count` cards — the count-based loader the scroll view grows on demand.
    static func window(_ cards: [FeedCard], count: Int) -> [FeedCard] {
        Array(cards.prefix(max(0, count)))
    }
}
