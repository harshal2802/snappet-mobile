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


    /// Videos / Photos — a post matches when ANY of its clips is that kind. Posts stay whole: the filter
    /// decides which POSTS show, never which clips within one, so the carousel, attempt labels, and
    /// clip counts are untouched.
    enum MediaKind: String, Sendable { case all, videos, photos }

    var query: String = ""
    /// One ACTIVITY at a time (prompt 170): Climbing · Strength · Cardio · Dance · Mobility · Festival · Other,
    /// matched against the post's resolved activity (`ClipActivity`) — so a Quick Session climb or a climbing
    /// workout imported from Health is Climbing, not "Gym". nil = all. Mutually exclusive by construction.
    var activity: ClipFeedPost.Discipline? = nil
    /// One FESTIVAL (its pack id) — prompt 171: a chip per festival you have clips from. Exclusive with
    /// `activity` (one "what" at a time); the chip strip enforces it.
    var festivalPack: String? = nil
    /// Inside a festival: one artist, or the clips not matched to an artist yet.
    enum ArtistPick: Equatable, Sendable { case artist(String), untagged }
    var festivalArtist: ArtistPick? = nil
    var kind: MediaKind = .all
    var favoritesOnly: Bool = false
    /// Show only posted highlight reels (highlights P2). Stacks with the other chips, like Favorites.
    var reelsOnly: Bool = false
    /// Show only climbs sent or flashed that session (prompt 161). Stacks with the other chips.
    var sendsOnly: Bool = false
    /// Show ONLY the clips hidden from Clips (prompt 164) — where you go to unhide them.
    var showHidden: Bool = false

    /// The query with edge whitespace dropped — what matching + the "no results for X" copy both use.
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether anything narrows the feed — drives the "N of M posts · Clear" line, the no-match state,
    /// and the fast path (inactive ⇒ `apply` returns the input untouched).
    var isActive: Bool {
        !trimmedQuery.isEmpty || activity != nil || festivalPack != nil || kind != .all || favoritesOnly || reelsOnly || sendsOnly
            || showHidden
    }

    /// One-tap recovery: the default (all-off) filter.
    static let cleared = ClipFeedFilter()

    /// Hidden clips (prompt 164) leave their posts; a post with nothing left disappears. With `showHidden`
    /// it's the reverse — only hidden clips, so they can be found and unhidden. Posts stay whole otherwise
    /// (attempt labels keep their real numbers). Fast path: nothing hidden and not showing hidden → input.
    static func withHidden(_ posts: [ClipFeedPost], hidden: Set<UUID>, showHidden: Bool) -> [ClipFeedPost] {
        guard showHidden || !hidden.isEmpty else { return posts }
        return posts.compactMap { post in
            let kept = post.clips.filter { hidden.contains($0.media.id) == showHidden }
            guard !kept.isEmpty else { return nil }
            if kept.count == post.clips.count { return post }
            var p = post
            p.clips = kept
            return p
        }
    }

    /// Filter `posts` down to the visible set. `isFavorite` injects the reaction store lookup so the
    /// UserDefaults edge stays out of the pure layer (and is only consulted when `favoritesOnly` is on).
    func apply(_ posts: [ClipFeedPost], isFavorite: (ClipFeedPost) -> Bool,
               searchContext: ClipSearch.Context = .current) -> [ClipFeedPost] {
        guard isActive else { return posts }
        let q = trimmedQuery
        // Built once per apply (formatters + relative ranges), not per post (prompt 165).
        let search = q.isEmpty ? nil : ClipSearch(query: q, context: searchContext)
        return posts.filter { post in
            if favoritesOnly, !isFavorite(post) { return false }
            if reelsOnly, !post.isReel { return false }
            if sendsOnly, post.climbResult?.status.isSend != true { return false }
            if let activity, post.discipline != activity { return false }
            if let pack = festivalPack {
                guard post.festival?.packID == pack else { return false }
                switch festivalArtist {
                case .artist(let a)?: if post.festival?.artist != a { return false }
                case .untagged?: if post.festival?.artist != nil { return false }
                case nil: break
                }
            }
            switch kind {
            case .all: break
            case .videos: if !post.clips.contains(where: { $0.media.kind == "video" }) { return false }
            case .photos: if !post.clips.contains(where: { $0.media.kind == "photo" }) { return false }
            }
            // Every word must match something the user remembers (prompt 165): name, session, grade,
            // angle, outcome, date words, or a relative range ("last week"). `localizedStandardContains`
            // = case- and diacritic-insensitive, the same matching Spotlight-style search uses.
            if let search, !search.matches(post) { return false }
            return true
        }
    }
}
