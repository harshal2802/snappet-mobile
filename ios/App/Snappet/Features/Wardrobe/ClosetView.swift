import SwiftUI
import SwiftData

/// The digital closet: search + filter chips + category-sectioned grid with wear pills.
/// Amber pill = rarely-worn nudge (perf ramp, not wayfinding). Coral FAB = add.
struct ClosetView: View {
    @Binding var showCapture: Bool

    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]

    @State private var searchText = ""
    @State private var categoryFilter: GarmentCategory?
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
            if let categoryFilter, item.category != categoryFilter { return false }
            guard !query.isEmpty else { return true }
            return item.name.lowercased().contains(query)
                || item.material.lowercased().contains(query)
                || item.colorRaw.contains(query)
                || item.styleRaw.lowercased().contains(query)
                || item.category.title.lowercased().contains(query)
        }
    }

    private var sections: [(category: GarmentCategory, items: [WardrobeItem])] {
        GarmentCategory.allCases.compactMap { cat in
            let inCat = filtered.filter { $0.category == cat }
            return inCat.isEmpty ? nil : (cat, inCat)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                filterChips
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 60)
                } else {
                    ForEach(sections, id: \.category) { section in
                        Text("\(section.category.pluralTitle) · \(section.items.count)")
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
                ForEach([GarmentCategory.top, .bottom, .shoes, .outerwear, .dress, .accessory], id: \.self) { cat in
                    chip(cat.pluralTitle, isOn: categoryFilter == cat) {
                        categoryFilter = categoryFilter == cat ? nil : cat
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
            Text([item.style.title, item.material].filter { !$0.isEmpty }.joined(separator: " · "))
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
struct WardrobeItemTile: View {
    let item: WardrobeItem
    var height: CGFloat = 96

    var body: some View {
        Group {
            if let data = item.imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
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
    }
}
