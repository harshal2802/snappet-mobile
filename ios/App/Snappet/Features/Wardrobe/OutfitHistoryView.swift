import SwiftUI
import SwiftData

/// The Outfits surface: Saved / Favorites / Worn segments over `WardrobeOutfit` rows.
/// "Wear again" re-logs every piece in one tap and refreshes the outfit's lastWornAt.
struct OutfitHistoryView: View {
    private enum Segment: String, CaseIterable, Identifiable {
        case saved, favorites, worn
        var id: String { rawValue }
        var title: String {
            switch self {
            case .saved: return "Saved"
            case .favorites: return "Favorites ♥"
            case .worn: return "Worn"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query(sort: \WardrobeOutfit.createdAt, order: .reverse) private var outfits: [WardrobeOutfit]
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]

    @State private var segment: Segment = .saved

    private var shown: [WardrobeOutfit] {
        switch segment {
        case .saved: return outfits
        case .favorites: return outfits.filter(\.isFavorite)
        case .worn: return outfits.filter { $0.lastWornAt != nil }
                .sorted { ($0.lastWornAt ?? .distantPast) > ($1.lastWornAt ?? .distantPast) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Filter", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if shown.isEmpty {
                    ContentUnavailableView("No outfits here yet", systemImage: "square.grid.2x2",
                        description: Text("Generate one from For You and tap Save or Wear today."))
                        .padding(.top, 40)
                } else {
                    ForEach(shown) { outfit in
                        OutfitHistoryCard(outfit: outfit, items: items,
                                          onWearAgain: { wearAgain(outfit) },
                                          onToggleFavorite: {
                                              outfit.isFavorite.toggle()
                                              try? modelContext.save()
                                          },
                                          onDelete: {
                                              modelContext.delete(outfit)
                                              try? modelContext.save()
                                          })
                    }
                    Text("Wearing an outfit updates each item's wear log & cost-per-wear.")
                        .font(.system(size: 10))
                        .foregroundStyle(SnappetColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .background(SnappetColor.paper)
    }

    private func wearAgain(_ outfit: WardrobeOutfit) {
        for id in outfit.itemIDs {
            modelContext.insert(WearEvent(itemID: id, outfitID: outfit.id))
        }
        outfit.lastWornAt = .now
        try? modelContext.save()
        core.log(module: "wardrobe", action: "wear", summary: "Wore outfit again: \(outfit.title)")
    }
}

private struct OutfitHistoryCard: View {
    let outfit: WardrobeOutfit
    let items: [WardrobeItem]
    var onWearAgain: () -> Void
    var onToggleFavorite: () -> Void
    var onDelete: () -> Void

    private var dateLine: String {
        if let worn = outfit.lastWornAt {
            return worn.formatted(.dateTime.month(.abbreviated).day())
        }
        return outfit.createdAt.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(outfit.title.isEmpty ? outfit.occasion.title : outfit.title)
                    .font(.subheadline.weight(.bold))
                if outfit.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SnappetColor.wardrobe)
                }
                Spacer()
                Text(dateLine)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
                Menu {
                    Button(action: onToggleFavorite) {
                        Label(outfit.isFavorite ? "Unfavorite" : "Favorite", systemImage: "heart")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete outfit", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SnappetColor.textSecondary)
                        .padding(4)
                }
            }
            HStack(spacing: 8) {
                ForEach(outfit.itemIDs, id: \.self) { id in
                    if let item = items.first(where: { $0.id == id }) {
                        WardrobeItemTile(item: item, height: 50)
                            .frame(width: 50)
                    }
                }
                Spacer()
                Button("Wear again ›", action: onWearAgain)
                    .font(.caption.weight(.bold))
                    .tint(SnappetColor.wardrobe)
                    .accessibilityIdentifier("wardrobe.outfits.wearAgain")
            }
        }
        .padding(12)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
    }
}
