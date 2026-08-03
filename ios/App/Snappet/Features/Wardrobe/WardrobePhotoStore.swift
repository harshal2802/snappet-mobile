import SwiftData
import UIKit

// The SwiftData half of multi-photo (wardrobe prompt 04). Every decision it makes comes from the
// pure `WardrobePhotoSet`; this file only executes plans and moves bytes. Two rules it exists to
// enforce in ONE place:
//
// 1. **Every photo is written through `WardrobeImageStore`.** A photo stored any other way
//    re-creates the 1.01 GB bug prompt 03 fixed.
// 2. **The cover lives on `WardrobeItem`, the extras are rows.** That asymmetry is the reason
//    "make cover" and "delete the cover" are byte-copies rather than pointer swaps.

@MainActor
enum WardrobePhotoStore {

    /// Extra photos for an item, in display order.
    static func extras(for itemID: UUID, in context: ModelContext) -> [WardrobePhoto] {
        let all = (try? context.fetch(FetchDescriptor<WardrobePhoto>())) ?? []
        return all.filter { $0.itemID == itemID }
            .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    /// Total photo count including the item-hosted cover.
    static func photoCount(for item: WardrobeItem, in context: ModelContext) -> Int {
        (item.imageData == nil ? 0 : 1) + extras(for: item.id, in: context).count
    }

    /// The ordered display list the carousel and the manage grid both render from.
    static func ordered(for item: WardrobeItem, in context: ModelContext) -> [WardrobePhotoSet.Entry] {
        WardrobePhotoSet.ordered(
            coverRole: item.imageData == nil ? nil : item.coverPhotoRole,
            extras: extras(for: item.id, in: context).map { ($0.id, $0.role) })
    }

    // MARK: - Adding

    /// Encode `image` through the prompt-03 pipeline and append it as an extra photo.
    /// Returns false when the cap refuses it, so the caller can surface the reason.
    /// - Parameter isCutout: whether `image` actually carries an alpha cut-out. Defaults to what
    ///   the role asks for, but the caller should pass the truth — subject lift can FAIL, and
    ///   PNG-encoding an opaque photo just wastes bytes for no alpha.
    @discardableResult
    static func addExtra(_ image: UIImage, role: GarmentPhotoRole, isCutout: Bool? = nil,
                         to item: WardrobeItem, in context: ModelContext) async -> Bool {
        let current = extras(for: item.id, in: context)
        guard WardrobePhotoSet.canAdd(currentCount: photoCount(for: item, in: context)) else {
            return false
        }
        let isCutout = isCutout ?? role.shouldLiftSubject
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            WardrobeImageStore.prepare(image: image, isCutout: isCutout)
        }).value else { return false }

        context.insert(WardrobePhoto(
            itemID: item.id, role: role,
            sortIndex: WardrobePhotoSet.nextSortIndex(existing: current.map(\.sortIndex)),
            imageData: prepared.display, thumbnailData: prepared.thumbnail))
        try? context.save()
        return true
    }

    // MARK: - Mutating

    static func setRole(_ role: GarmentPhotoRole, on photo: WardrobePhoto,
                        in context: ModelContext) {
        photo.role = role
        try? context.save()
    }

    /// Promote an extra to cover by **swapping bytes** with the item — the cover is a slot on
    /// `WardrobeItem`, not a pointer, so the old cover has to go somewhere and the promoted row
    /// is exactly where it belongs. A swap (rather than copy + delete) also keeps the photo count
    /// stable, which is what the user expects from "make cover".
    static func makeCover(_ photo: WardrobePhoto, of item: WardrobeItem, in context: ModelContext) {
        let oldImage = item.imageData
        let oldThumb = item.thumbnailData
        let oldRole = item.coverPhotoRole

        item.imageData = photo.imageData
        item.thumbnailData = photo.thumbnailData
        item.coverPhotoRole = photo.role

        photo.imageData = oldImage
        photo.thumbnailData = oldThumb
        photo.role = oldRole
        try? context.save()
    }

    /// Reorder the extras to match `ids`, renumbering so gaps don't accumulate.
    static func reorder(_ ids: [UUID], for itemID: UUID, in context: ModelContext) {
        let map = WardrobePhotoSet.renumbered(ids)
        for photo in extras(for: itemID, in: context) {
            if let index = map[photo.id] { photo.sortIndex = index }
        }
        try? context.save()
    }

    // MARK: - Deleting

    /// Execute the pure delete plan. Cover deletion promotes first, then removes — never the other
    /// way round, or a garment with photos renders the category emoji if we die between writes.
    static func delete(_ entry: WardrobePhotoSet.Entry, from item: WardrobeItem,
                       in context: ModelContext) {
        let rows = extras(for: item.id, in: context)
        let plan = WardrobePhotoSet.deletePlan(
            target: entry, extras: rows.filter { $0.id != entry.id }.map { ($0.id, $0.role) })

        switch plan {
        case let .removeExtra(id):
            if let row = rows.first(where: { $0.id == id }) { context.delete(row) }
        case let .promoteThenRemove(promoting, role):
            guard let row = rows.first(where: { $0.id == promoting }) else { return }
            item.imageData = row.imageData
            item.thumbnailData = row.thumbnailData
            item.coverPhotoRole = role
            context.delete(row)
        case .clearCover:
            item.imageData = nil
            item.thumbnailData = nil
            item.coverPhotoRole = .front
        }
        try? context.save()
        reorder(extras(for: item.id, in: context).map(\.id), for: item.id, in: context)
    }

    /// Sweep an item's photo rows. **Must** be called when deleting an item: the FK is a plain
    /// UUID with no SwiftData relationship, so nothing cascades and the rows would be orphaned
    /// bytes that never get reclaimed.
    static func deleteAll(forItem itemID: UUID, in context: ModelContext) {
        for photo in extras(for: itemID, in: context) { context.delete(photo) }
        try? context.save()
    }
}
