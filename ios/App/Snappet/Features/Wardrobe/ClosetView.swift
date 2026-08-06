import SwiftUI
import SwiftData

/// The digital closet: search + filter chips + category-sectioned grid with wear pills.
/// Amber pill = rarely-worn nudge (perf ramp, not wayfinding). Coral FAB = add.
struct ClosetView: View {
    @Binding var showCapture: Bool

    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]

    @State private var searchText = ""
    /// The stored category RAW, not a `GarmentCategory` — a custom category ("Loungewear") has no
    /// enum case, and filtering on the enum silently folded it into whatever built-in it scores as.
    @State private var categoryFilter: String?
    @State private var favoritesOnly = false

    private var stats: [UUID: WearStats.ItemStats] {
        WearStats.byItem(
            wornItemIDs: wearEvents.compactMap { e in e.itemID.map { ($0, e.wornOn) } },
            costs: items.reduce(into: [:]) { acc, item in acc[item.id] = item.cost })
    }

    private var filtered: [WardrobeItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            guard !item.isArchived else { return false }
            if favoritesOnly && !item.isFavorite { return false }
            if let categoryFilter, item.categoryRaw != categoryFilter { return false }
            guard !query.isEmpty else { return true }
            // Brand and size are searchable too — they're the facts you'd actually reach for
            // ("that Uniqlo one", "everything in M"), and omitting them made prompt 05's fields
            // invisible to search as well as to the eye.
            return item.name.lowercased().contains(query)
                || item.brand.lowercased().contains(query)
                || item.sizeLabel.lowercased().contains(query)
                || item.material.lowercased().contains(query)
                || item.colorRaw.lowercased().contains(query)
                || item.styleRaw.lowercased().contains(query)
                || item.categoryRaw.lowercased().contains(query)
        }
    }

    /// ONE grouping pass over the filtered set. This used to call `filtered.filter` once per
    /// category (8×) on top of the `.isEmpty` check — and `filtered` is a computed property, so
    /// every one of those was a fresh O(n) scan, on every body pass.
    /// Grouped by the stored RAW, so a custom category gets its own section under the user's own
    /// wording instead of being folded into whatever built-in it scores as.
    private var sections: [(category: WardrobeClosetGrouping.Category, items: [WardrobeItem])] {
        let grouped = Dictionary(grouping: filtered, by: \.categoryRaw)
        return WardrobeClosetGrouping.present(in: filtered.map(\.categoryRaw), plural: true)
            .compactMap { category in
                guard let inCat = grouped[category.key], !inCat.isEmpty else { return nil }
                return (category, inCat)
            }
    }

    var body: some View {
        // Evaluate the derived collections ONCE per body pass rather than once per read.
        let sections = sections
        let stats = stats
        return ScrollView {
            // Plain VStack, not Lazy: there are at most 8 sections, and a LazyVGrid nested inside
            // a LazyVStack largely defeats laziness (the outer stack needs each grid's height, so
            // tiles materialize well ahead of the viewport). The grids below stay lazy — that is
            // where the 100 tiles actually live.
            VStack(alignment: .leading, spacing: 8) {
                filterChips
                if sections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 60)
                } else {
                    ForEach(sections, id: \.category.key) { section in
                        Text("\(section.category.title) · \(section.items.count)")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                            ForEach(section.items) { item in
                                NavigationLink(value: item) {
                                    ClosetItemCard(item: item, stats: stats[item.id] ?? .init())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .background(SnappetColor.paper)
        .searchable(text: $searchText, prompt: "Search closet")
        .overlay(alignment: .bottomTrailing) {
            Button {
                showCapture = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(SnappetColor.brand, in: Circle())
                    .shadow(color: SnappetColor.brand.opacity(0.4), radius: 12, y: 6)
            }
            .padding(.trailing, 18)
            .padding(.bottom, 14)
            .accessibilityIdentifier("wardrobe.closet.add")
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All · \(items.filter { !$0.isArchived }.count)",
                     isOn: categoryFilter == nil && !favoritesOnly) {
                    categoryFilter = nil; favoritesOnly = false
                }
                // Pinned built-ins plus any CUSTOM category the closet actually contains, so a
                // user-defined category is reachable from quick-select like any other.
                ForEach(WardrobeClosetGrouping.filterChips(
                    presentKeys: items.filter { !$0.isArchived }.map(\.categoryRaw))) { cat in
                    chip(cat.title, isOn: categoryFilter == cat.key) {
                        categoryFilter = categoryFilter == cat.key ? nil : cat.key
                    }
                }
                chip("♥", isOn: favoritesOnly) { favoritesOnly.toggle() }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? SnappetColor.wardrobe : SnappetColor.surface, in: Capsule())
                .foregroundStyle(isOn ? .white : SnappetColor.textSecondary)
                .overlay(Capsule().strokeBorder(isOn ? .clear : SnappetColor.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// One closet tile: cut-out (or category emoji), wear pill, favorite heart, name + meta.
struct ClosetItemCard: View {
    let item: WardrobeItem
    let stats: WearStats.ItemStats

    private var rarelyWorn: Bool {
        WearStats.isRarelyWorn(wearCount: stats.wearCount, lastWornAt: stats.lastWornAt, now: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WardrobeItemTile(item: item, height: 96)
                .overlay(alignment: .topLeading) {
                    Text(WearStats.pillLabel(wearCount: stats.wearCount, lastWornAt: stats.lastWornAt,
                                             addedAt: item.createdAt, now: .now))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(rarelyWorn ? SnappetColor.perfModerate.opacity(0.9) : Color.black.opacity(0.7),
                                    in: Capsule())
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SnappetColor.wardrobe)
                            .padding(8)
                    }
                }
            Text(item.name)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .padding(.top, 6)
            // Brand · size · style. Brand leads because it's the fact you scan a closet for, and
            // `styleDisplay` (not `style.title`) so a CUSTOM style shows the user's own wording
            // rather than the built-in it happens to score as.
            Text([item.brand, item.sizeLabel, item.styleDisplay]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SnappetColor.textSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
    }
}

/// The item image tile: cut-out photo when present, category emoji placeholder otherwise.
///
/// Prefers **`thumbnailData`** (wardrobe prompt 03). This view renders at nine sites between 38pt
/// and 100pt; decoding the full master at each of them via `UIImage(data:)` is what made the closet
/// hang — that materializes the whole 3024×2820 bitmap (~34 MB) to fill a tile ~110× smaller.
/// The decode runs off-main through `WardrobeImageCache` and is reused across scroll passes.
///
/// **Falls back to the master while the migration is still catching up.** An earlier revision showed
/// the category emoji instead, which reads as data loss — and the reasoning behind it was wrong:
/// the stall came from `UIImage(data:)`, not from the master's size. `WardrobeImageStore.decode`
/// downsamples *during* decode (`CGImageSourceCreateThumbnailAtIndex`) and never materializes the
/// full bitmap, so the fallback costs a bigger file read and the same small decode. Transient
/// either way — `WardrobeImageMigration` backfills the thumbnail and the fallback stops firing.
struct WardrobeItemTile: View {
    let item: WardrobeItem
    var height: CGFloat = 96

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Text(item.category.emoji)
                    .font(.system(size: height * 0.52))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: tileIdentity) {
            // Reset first: SwiftUI recycles tile identities while scrolling, and without this the
            // previous garment's photo lingers under the new one's name until the decode lands.
            image = nil
            // Empty thumbnail = the migration's "known-undecodable" marker; it must NOT fall
            // through to the master, or an unreadable blob is retried on every appearance.
            if let thumb = item.thumbnailData {
                guard !thumb.isEmpty else { return }
                image = await WardrobeImageCache.image(itemID: item.id, slot: .thumbnail,
                                                       data: thumb, pointHeight: height)
                return
            }
            // Pre-migration fallback. `imageData` is `.externalStorage`, so touching it is a file
            // read — deliberately confined to here (once per tile, off the render pass) and kept
            // out of `tileIdentity`, which is evaluated on every body pass.
            guard let master = item.imageData, !master.isEmpty else { return }
            image = await WardrobeImageCache.image(itemID: item.id, slot: .hero,
                                                   data: master, pointHeight: height)
        }
    }

    /// Byte count in the identity so the migration backfilling a thumbnail re-decodes the tile,
    /// while an unrelated body pass does not. Reads ONLY the inline `thumbnailData` — pulling in
    /// the externalStorage master here would turn every body pass into a 10 MB file read.
    /// `-1` distinguishes "no thumbnail yet" from a zero-length one.
    private var tileIdentity: String {
        "\(item.id.uuidString)#\(item.thumbnailData?.count ?? -1)#\(Int(height))"
    }
}

/// The 240pt hero on the item detail screen — the one place that reads the full display master.
struct WardrobeItemHeroImage: View {
    let item: WardrobeItem
    var height: CGFloat = 240

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if item.imageData != nil {
                // Photo exists but hasn't decoded yet — a spinner, not the emoji, so the hero
                // doesn't flash a placeholder on every push.
                ProgressView().controlSize(.small)
            } else {
                Text(item.category.emoji)
                    .font(.system(size: height * 0.52))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: "\(item.id.uuidString)#\(item.imageData?.count ?? 0)") {
            image = nil
            guard let data = item.imageData, !data.isEmpty else { return }
            image = await WardrobeImageCache.image(itemID: item.id, slot: .hero,
                                                   data: data, pointHeight: height)
        }
    }
}
