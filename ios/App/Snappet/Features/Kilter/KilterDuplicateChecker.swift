import Foundation

/// Validates a freshly-authored climb (manual *or* generated) against everything already on the device
/// before it's saved — the user's brief: *"when a user saves, the app should validate that climb with all
/// the downloaded dataset for duplicates; same applies for model-generated climbs."*
///
/// Duplicate ≡ same **canonical** hold set on the same layout (`KilterClimbIdentity.canonicalKey`), so the
/// match is order-independent: placing the same holds in a different sequence still collides. The index
/// covers both sources:
/// - the read-only **catalog** (the downloaded dataset) — matched by canonical frames, since catalog
///   climbs carry Aurora's own random uuids, not our content uuid;
/// - the user's previously **created** climbs — which *do* carry the deterministic content uuid, so the
///   same climb authored twice (even on another device, then synced in) collapses onto one entry.
///
/// Layout-scoped (built per layout) because a `placement_id` only means something within its layout. Pure
/// core (`init` + `find`) is unit-tested without a device; `build(...)` is the main-actor convenience that
/// reads the installed catalog.
struct KilterDuplicateChecker {
    /// A climb the authored one duplicates.
    struct Duplicate: Equatable {
        enum Origin: Equatable {
            case catalog   // an existing climb in the downloaded dataset
            case created   // one the user already authored on this device
        }
        let uuid: String
        let name: String
        let setter: String
        let origin: Origin
    }

    /// `canonicalKey -> Duplicate`.
    private let index: [String: Duplicate]
    let layoutId: Int

    /// Build the index from raw catalog rows + the user's created climbs (both already scoped to one
    /// layout). A created climb shadows a catalog climb with the same holds (the user's own copy wins in
    /// the "already exists" message). Pure → testable with hand-built rows.
    init(catalogRows: [(uuid: String, name: String, setter: String, frames: String)],
         createdClimbs: [(uuid: String, name: String, setter: String, layoutId: Int, frames: String)],
         layoutId: Int) {
        self.layoutId = layoutId
        var idx: [String: Duplicate] = [:]
        for r in catalogRows {
            let key = KilterClimbIdentity.canonicalKey(layoutId: layoutId, frames: r.frames)
            if idx[key] == nil {
                idx[key] = Duplicate(uuid: r.uuid, name: r.name, setter: r.setter, origin: .catalog)
            }
        }
        for c in createdClimbs where c.layoutId == layoutId {
            let key = KilterClimbIdentity.canonicalKey(layoutId: layoutId, frames: c.frames)
            idx[key] = Duplicate(uuid: c.uuid, name: c.name, setter: c.setter, origin: .created)
        }
        self.index = idx
    }

    /// The existing climb this `(layout, frames)` duplicates, or `nil` if it's new. The frames need not be
    /// canonical — `find` canonicalizes before lookup.
    func find(layoutId: Int, frames: String) -> Duplicate? {
        guard layoutId == self.layoutId else { return nil }
        return index[KilterClimbIdentity.canonicalKey(layoutId: layoutId, frames: frames)]
    }

    /// Build a checker for one layout from the installed catalog + the user's created climbs. Main-actor
    /// because it reads `KilterCatalog` (main-thread-only). Reads the catalog's climbs once per call —
    /// cheap (one indexed SELECT over a layout) and always current, so it's built fresh at save time.
    @MainActor
    static func build(layoutId: Int, created: [KilterCreatedClimb],
                      catalog: KilterCatalog = .shared) -> KilterDuplicateChecker {
        let rows = catalog.climbFramesForDedup(forLayout: layoutId)
        let createdTuples = created.map {
            (uuid: $0.uuid, name: $0.name, setter: $0.setterUsername, layoutId: $0.layoutId, frames: $0.frames)
        }
        return KilterDuplicateChecker(catalogRows: rows, createdClimbs: createdTuples, layoutId: layoutId)
    }
}
