import Foundation

// MARK: - Clips feed — optional search + filter (prompt 107, pure)
//
// The Clips tab's search + chip-filter state and its application to the composed posts. PURE — plain
// value logic over `[ClipFeedPost]`, no SwiftUI/SwiftData — so it unit-tests in `SnappetTests`
// (`ClipFeedFilterTests`). The view owns ONE of these in `@State`; the explore grid receives the same
// filtered posts, so the feed and the grid can never disagree on what's visible.
//
// Design (wireframes in docs/ux-research/clips-search-filter/): zero-cost when idle — `isActive == false`
// returns the input array untouched (no allocation, no reaction-store reads), so browsing without
// searching/filtering costs nothing and registers no extra SwiftUI dependencies.
struct ClipFeedFilter: Equatable, Sendable {

    /// Climbs / Gym / 🎪 Festival — one value ⇒ the chips are mutually exclusive by construction
    /// (selecting one deselects the other), matching the Kilter browse chips. Climbs/Gym map to
    /// `ClipFeedPost.kind`; Festival maps to `post.discipline == .festival` (festival posts ride a
    /// gym-kind dance session, so kind alone can't tell them apart — festival prompt 03).
    enum Discipline: String, Sendable { case all, climbs, gym, festival }

    /// Videos / Photos — a post matches when ANY of its clips is that kind. Posts stay whole: the filter
    /// decides which POSTS show, never which clips within one, so the carousel, attempt labels, and
    /// clip counts are untouched.
    enum MediaKind: String, Sendable { case all, videos, photos }

    var query: String = ""
    var discipline: Discipline = .all
    var kind: MediaKind = .all
    var favoritesOnly: Bool = false
    /// Show only posted highlight reels (highlights P2). Stacks with the other chips, like Favorites.
    var reelsOnly: Bool = false

    /// The query with edge whitespace dropped — what matching + the "no results for X" copy both use.
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether anything narrows the feed — drives the "N of M posts · Clear" line, the no-match state,
    /// and the fast path (inactive ⇒ `apply` returns the input untouched).
    var isActive: Bool { !trimmedQuery.isEmpty || discipline != .all || kind != .all || favoritesOnly || reelsOnly }

    /// One-tap recovery: the default (all-off) filter.
    static let cleared = ClipFeedFilter()

    /// Filter `posts` down to the visible set. `isFavorite` injects the reaction store lookup so the
    /// UserDefaults edge stays out of the pure layer (and is only consulted when `favoritesOnly` is on).
    func apply(_ posts: [ClipFeedPost], isFavorite: (String) -> Bool) -> [ClipFeedPost] {
        guard isActive else { return posts }
        let q = trimmedQuery
        return posts.filter { post in
            if favoritesOnly, !isFavorite(post.id) { return false }
            if reelsOnly, !post.isReel { return false }
            switch discipline {
            case .all: break
            case .climbs: if post.kind != .kilter { return false }
            // A festival post's session IS a gym-kind WorkoutSession — exclude it from Gym so the
            // two chips partition cleanly (a dance set is not a workout post).
            case .gym: if post.kind != .gym || post.discipline == .festival { return false }
            case .festival: if post.discipline != .festival { return false }
            }
            switch kind {
            case .all: break
            case .videos: if !post.clips.contains(where: { $0.media.kind == "video" }) { return false }
            case .photos: if !post.clips.contains(where: { $0.media.kind == "photo" }) { return false }
            }
            if !q.isEmpty {
                // Match the fields a user actually remembers: the climb/exercise name (post title) and
                // the session title (subtitle). `localizedStandardContains` = case- and
                // diacritic-insensitive, the same matching Spotlight-style search uses.
                if !post.title.localizedStandardContains(q),
                   !post.subtitle.localizedStandardContains(q) { return false }
            }
            return true
        }
    }
}
