import Foundation

// MARK: - Feed wall layout — pure balanced masonry distributor
//
// `FeedWallLayout` turns an ordered list of `FeedCard`s into a fixed number of
// columns for a Pinterest-style masonry wall. It is pure Foundation (no SwiftUI),
// so it unit-tests without a simulator and the Kotlin port mirrors it 1:1.
//
// Balance strategy: greedy shortest-column-first by *item count* (not pixel
// height — heights aren't known at this layer). Each card, in input order, goes
// to the column holding the fewest items so far; ties resolve to the lowest
// index. This keeps columns within one item of each other and is deterministic.

enum FeedWallLayout {

    /// Distribute `cards` (in order) across `columns` balanced columns.
    ///
    /// - Each card lands in the column with the fewest items so far (ties → lowest index).
    /// - Input order is preserved *within* each column.
    /// - Always returns exactly `columns` arrays (some may be empty if there are
    ///   fewer cards than columns).
    /// - `columns` is clamped to `>= 1`.
    static func distribute(_ cards: [FeedCard], columns: Int) -> [[FeedCard]] {
        let columnCount = max(1, columns)
        var result = [[FeedCard]](repeating: [], count: columnCount)

        for card in cards {
            // Pick the shortest column; ties resolve to the lowest index because
            // we only switch when a strictly-shorter column appears.
            var target = 0
            for index in 1..<columnCount where result[index].count < result[target].count {
                target = index
            }
            result[target].append(card)
        }

        return result
    }

    /// The recommended column count for a given wall width.
    /// Narrow widths (phones / compact) get 2 columns; wider widths get 3.
    static func columnCount(forWidth width: Double) -> Int {
        width < 500 ? 2 : 3
    }
}
