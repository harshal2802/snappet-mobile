import SwiftUI
import SwiftData

/// A small main-actor cache of decoded board renders so a scrolling grid / timeline / rail computes each
/// climb's holds + geometry from the SQLite-backed catalog **once**, not on every frame or re-render.
/// `@Observable` so a freshly-decoded render triggers a redraw of just the asking view.
///
/// Shared across features (extracted from P2's `KilterCreatedView` so On the Board's timeline rows + the
/// root recent rail reuse the SAME cache instead of hitting `catalog.climb/holds/boardGeometry` on the
/// main thread per row per re-render, F5):
///   - `render(for created:catalog:)` keys on a created climb's content `uuid` (its authored size).
///   - `render(forCatalogUUID:sizeId:catalog:)` keys on `uuid|sizeId`, since the SAME catalog climb can be
///     lit at different board sizes (a different hole set), so each size is a distinct render.
@Observable @MainActor
final class KilterThumbnailCache {
    struct Render { let geometry: KilterBoardGeometry; let holds: [KilterHold] }
    private var cache: [String: Render] = [:]

    /// The decoded render for a created climb (lazy: computed + cached on first ask). Renders against the
    /// climb's authored `sizeId` so the thumbnail matches the board it was set for. Returns `nil` only on
    /// an empty/undecodable climb (the card then shows its placeholder).
    func render(for climb: KilterCreatedClimb, catalog: KilterCatalog) -> Render? {
        if let hit = cache[climb.uuid] { return hit }
        let asClimb = climb.asClimb
        let holds = catalog.holds(for: asClimb, sizeId: climb.sizeId)
        let geometry = catalog.boardGeometry(forLayout: climb.layoutId, sizeId: climb.sizeId)
        guard !holds.isEmpty else { return nil }
        let render = Render(geometry: geometry, holds: holds)
        cache[climb.uuid] = render
        return render
    }

    /// The decoded render for a CATALOG climb by uuid at a specific board size (lazy + cached). Keyed by
    /// `uuid|sizeId` so the same climb lit at two sizes caches as two distinct renders. Returns `nil` when
    /// the catalog lacks the climb (e.g. a created climb On the Board can't resolve) or it has no holds, so
    /// the caller falls back to its placeholder tile.
    func render(forCatalogUUID uuid: String, sizeId: Int, catalog: KilterCatalog) -> Render? {
        let key = "\(uuid)|\(sizeId)"
        if let hit = cache[key] { return hit }
        guard let climb = catalog.climb(uuid) else { return nil }
        let holds = catalog.holds(for: climb, sizeId: sizeId)
        let geometry = catalog.boardGeometry(forLayout: climb.layoutId, sizeId: sizeId)
        guard !holds.isEmpty else { return nil }
        let render = Render(geometry: geometry, holds: holds)
        cache[key] = render
        return render
    }

    /// Drop cache entries for created climbs that no longer exist (deleted / edited into a new identity).
    /// Matches on the created-climb key (the bare `uuid`); the catalog `uuid|sizeId` entries are a bounded,
    /// read-only set (a fixed catalog), so they don't need eviction.
    func evict(keeping uuids: Set<String>) {
        cache = cache.filter { entry in
            // Keep catalog renders (composite keys) and any created-climb key that still exists.
            entry.key.contains("|") || uuids.contains(entry.key)
        }
    }
}
