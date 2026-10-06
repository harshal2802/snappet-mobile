import Foundation
import SwiftData

// MARK: - Clips feed — favorite reactions (prompt 88 · made durable in prompt 162)
//
// Which Clips the user has hearted. For a PERSONAL on-device feed (your own clips), a social "like" records
// nothing, so the reaction is a "favorite".
//
// Prompt 162 moved it off UserDefaults (prompt 88), which had two holes:
// - **Backup dropped it** — the backup envelope is the SwiftData store; UserDefaults settings aren't in it.
// - **The heart was keyed by POST id** (`groupKey@sessionID`), a derived value: re-tagging a clip to a
//   festival set or another exercise changes the post id and silently un-hearts it.
// Favorites are now `FeedReaction` rows (the existing, already-backed-up "private reaction on content"
// model) keyed by the CLIP — `SessionMedia.id`, which survives regrouping, bakes and restore. A post is a
// favorite when any of its clips is; hearting a post hearts all of its clips. No new @Model.

/// Pure keys + the one-time legacy migration rule — unit-tested without a store.
enum ClipFavorites {
    /// `FeedReaction.typeRaw` for a Clips favorite (Recap reactions are "emoji" / "note").
    static let reactionType = "clipFavorite"
    /// `FeedReaction.activityContentId` namespace — never collides with a Recap card's content id.
    static let contentPrefix = "clipmedia:"
    /// The prompt-88 UserDefaults set of hearted POST ids, migrated once then removed.
    static let legacyDefaultsKey = "clips.favorites.v1"

    static func contentId(for mediaID: UUID) -> String { contentPrefix + mediaID.uuidString }

    static func mediaID(fromContentId id: String) -> UUID? {
        guard id.hasPrefix(contentPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(contentPrefix.count)))
    }

    /// The clips a legacy post-id heart now covers: every clip of each current post whose id was hearted.
    /// A legacy id that matches no current post was already orphaned by a regroup — it maps to nothing.
    static func migratedMediaIDs(legacyPostIDs: Set<String>, posts: [ClipFeedPost]) -> Set<UUID> {
        Set(posts.filter { legacyPostIDs.contains($0.id) }.flatMap { $0.clips.map(\.media.id) })
    }
}

@Observable @MainActor final class ClipReactionStore {
    private let defaults: UserDefaults
    private var context: ModelContext?
    /// Hearted clip ids (`SessionMedia.id`) — a cache of the `FeedReaction` rows, so the feed's per-card
    /// reads never fetch.
    private var mediaIDs: Set<UUID> = []

    /// `defaults` is injectable so the legacy migration unit-tests against a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Bind the store to the feed's context and load the rows. Safe to call on every feed rebuild: it
    /// re-reads, which is how a backup restore (rows replaced underneath) shows up.
    func attach(_ context: ModelContext) {
        self.context = context
        reload()
    }

    func reload() {
        guard let context else { return }
        let type = ClipFavorites.reactionType
        let rows = (try? context.fetch(FetchDescriptor<FeedReaction>(
            predicate: #Predicate { $0.typeRaw == type }))) ?? []
        let ids = Set(rows.compactMap { ClipFavorites.mediaID(fromContentId: $0.activityContentId) })
        if ids != mediaIDs { mediaIDs = ids }   // no observation churn when nothing changed
    }

    func isFavorite(_ post: ClipFeedPost) -> Bool {
        post.clips.contains { mediaIDs.contains($0.media.id) }
    }

    /// Heart → a row per clip in the post; un-heart → remove every clip's row (so a post never stays
    /// half-hearted).
    func toggle(_ post: ClipFeedPost) {
        let ids = Set(post.clips.map(\.media.id))
        if isFavorite(post) { remove(ids) } else { add(ids) }
    }

    var favoriteCount: Int { mediaIDs.count }

    /// One-time move of prompt-88 post-id hearts onto the posts' clips. Runs after a rebuild produced
    /// posts; the legacy key is removed only then, so an empty first compose can't drop them.
    func migrateLegacy(posts: [ClipFeedPost]) {
        guard !posts.isEmpty,
              let legacy = defaults.stringArray(forKey: ClipFavorites.legacyDefaultsKey) else { return }
        add(ClipFavorites.migratedMediaIDs(legacyPostIDs: Set(legacy), posts: posts))
        defaults.removeObject(forKey: ClipFavorites.legacyDefaultsKey)
    }

    private func add(_ ids: Set<UUID>) {
        let new = ids.subtracting(mediaIDs)
        guard let context, !new.isEmpty else { return }
        for id in new {
            context.insert(FeedReaction(activityContentId: ClipFavorites.contentId(for: id),
                                        typeRaw: ClipFavorites.reactionType))
        }
        try? context.save()
        mediaIDs.formUnion(new)
    }

    private func remove(_ ids: Set<UUID>) {
        guard let context else { return }
        let type = ClipFavorites.reactionType
        let contentIds = Set(ids.map(ClipFavorites.contentId(for:)))
        let rows = (try? context.fetch(FetchDescriptor<FeedReaction>(
            predicate: #Predicate { $0.typeRaw == type }))) ?? []
        for row in rows where contentIds.contains(row.activityContentId) { context.delete(row) }
        try? context.save()
        mediaIDs.subtract(ids)
    }
}
