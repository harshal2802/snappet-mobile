import Foundation

// The PURE half of "a garment has several photos" (wardrobe prompt 04): ordering, role assignment,
// the cap, and — the subtle one — what happens to the cover when a photo is deleted. No SwiftData,
// no UIKit, so all of it is unit-tested without a simulator; the views and the store just apply
// the plan this produces.
//
// The storage shape this reasons over is deliberately lopsided: the COVER lives on `WardrobeItem`
// (so the 100-tile closet grid never joins a second table to render, and existing one-photo
// garments needed no migration), while the extras are `WardrobePhoto` rows. Everything awkward
// about that asymmetry is confined to this file.

enum WardrobePhotoSet {

    /// Hard ceiling per garment. Not UI tidiness — storage: at prompt 03's caps a photo is roughly
    /// 1.2 MB master + 130 KB thumbnail, so six is ~8 MB, still under the 10 MB a *single* photo
    /// cost before prompt 03. A 100-item closet averaging three photos lands near 390 MB.
    static let maxPhotos = 6

    /// One photo's identity in display order, independent of where its bytes are stored.
    /// `id == nil` marks the cover (which lives on the item, not in a `WardrobePhoto` row).
    struct Entry: Equatable, Identifiable, Sendable {
        /// The `WardrobePhoto.id`, or nil for the item-hosted cover.
        var id: UUID?
        var role: GarmentPhotoRole
        var isCover: Bool

        init(id: UUID?, role: GarmentPhotoRole, isCover: Bool = false) {
            self.id = id
            self.role = role
            self.isCover = isCover
        }
    }

    /// What a delete implies for the caller. Kept as a value so the destructive sequencing is
    /// decided (and tested) here rather than inline in a view.
    enum DeletePlan: Equatable {
        /// Remove that `WardrobePhoto` row; the cover is untouched.
        case removeExtra(id: UUID)
        /// The cover was deleted: copy `promoting`'s bytes onto the item, then delete its row.
        /// Never leaves the garment photo-less while another photo exists.
        case promoteThenRemove(promoting: UUID, role: GarmentPhotoRole)
        /// The last photo went — clear the item's cover slots. The tile falls back to the emoji.
        case clearCover
    }

    /// Display order: cover first, then extras by `sortIndex`. `extras` is passed already sorted by
    /// the caller's fetch; ties and duplicate indices keep the given order (stable).
    static func ordered(coverRole: GarmentPhotoRole?,
                        extras: [(id: UUID, role: GarmentPhotoRole)]) -> [Entry] {
        var out: [Entry] = []
        if let coverRole {
            out.append(Entry(id: nil, role: coverRole, isCover: true))
        }
        out.append(contentsOf: extras.map { Entry(id: $0.id, role: $0.role) })
        return out
    }

    /// Whether another photo can be added.
    static func canAdd(currentCount: Int) -> Bool { currentCount < maxPhotos }

    /// Why an add was refused — surfaced to the user rather than silently dropped.
    static func addRefusalReason(currentCount: Int) -> String? {
        canAdd(currentCount: currentCount)
            ? nil
            : "A garment can hold up to \(maxPhotos) photos. Remove one to add another."
    }

    /// The role to pre-select in the add sheet: the first role not already used, so the common
    /// path (front → back → worn) is a single tap. Falls back to `.detail`, the one role that
    /// legitimately repeats — several close-ups of the same jacket is a reasonable thing to want.
    static func nextUnusedRole(used: [GarmentPhotoRole]) -> GarmentPhotoRole {
        let taken = Set(used)
        return GarmentPhotoRole.allCases.first { !taken.contains($0) } ?? .detail
    }

    /// The next `sortIndex` for an appended photo. Max+1 rather than count, so a set that has had
    /// deletions can't collide on an index that is still in use.
    static func nextSortIndex(existing: [Int]) -> Int {
        (existing.max() ?? -1) + 1
    }

    /// Re-number `sortIndex` to 0..<n after a reorder or delete, so gaps don't accumulate and the
    /// order is total. Returns the new index per id, in the given order.
    static func renumbered(_ ids: [UUID]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
    }

    /// What deleting `target` should do.
    ///
    /// Deleting the cover is the case worth being careful about: the item's cover slots must be
    /// refilled from the next photo *before* that photo's row goes away, or the garment briefly —
    /// or permanently, if the app is killed between the two writes — renders as a category emoji
    /// despite still having photos.
    static func deletePlan(target: Entry,
                           extras: [(id: UUID, role: GarmentPhotoRole)]) -> DeletePlan {
        guard target.isCover else {
            // Non-cover: `id` is always present for an extra; nothing to promote.
            return target.id.map { DeletePlan.removeExtra(id: $0) } ?? .clearCover
        }
        guard let next = extras.first else { return .clearCover }
        return .promoteThenRemove(promoting: next.id, role: next.role)
    }

    /// Whether the detail hero should show pager chrome (dots + role caption).
    /// A one-photo garment must look exactly as it did before prompt 04.
    static func showsPagerChrome(photoCount: Int) -> Bool { photoCount > 1 }
}
