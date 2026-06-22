import Foundation

// MARK: - Clips feed — favorite reactions (prompt 88)
//
// Persists which Clips POSTS the user has hearted — a Set of `ClipFeedPost.id` in UserDefaults. For a
// PERSONAL on-device feed (your own clips), a social "like" records nothing, so the reaction is a
// "favorite". Deliberately NOT SwiftData: favorites are a thin UI-layer overlay (the session stays the
// single source of truth for the clips themselves), so this adds no new `@Model` / no schema change —
// honouring the spirit of the Clips "no new persistence" principle.

@Observable @MainActor final class ClipReactionStore {
    private let key = "clips.favorites.v1"
    private let defaults: UserDefaults
    private var ids: Set<String>

    /// `defaults` is injectable so the store logic unit-tests against a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func isFavorite(_ postID: String) -> Bool { ids.contains(postID) }

    func toggle(_ postID: String) {
        if ids.contains(postID) { ids.remove(postID) } else { ids.insert(postID) }
        defaults.set(Array(ids), forKey: key)
    }

    var favoriteCount: Int { ids.count }
}
