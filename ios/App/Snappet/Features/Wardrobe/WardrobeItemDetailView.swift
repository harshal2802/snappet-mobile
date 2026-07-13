import SwiftUI
import SwiftData

/// One garment: hero cut-out, tag chips, wear stats, and the two module actions —
/// Style this (generator seeded with the piece) and Ask coach. Destructive ops live
/// in the ··· menu; cost-per-wear comes straight from the wear log.
struct WardrobeItemDetailView: View {
    @Bindable var item: WardrobeItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SnappetCore.self) private var core
    @Query private var wearEvents: [WearEvent]
    @Query private var allItems: [WardrobeItem]

    @State private var showGenerator = false
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var stats: WearStats.ItemStats {
        let mine = wearEvents.filter { $0.itemID == item.id }
        var s = WearStats.ItemStats(wearCount: mine.count, lastWornAt: mine.map(\.wornOn).max())
        if let cost = item.cost {
            s.costPerWear = WearStats.costPerWear(cost: cost, wears: mine.count)
        }
        return s
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WardrobeItemTile(item: item, height: 240)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            item.isFavorite.toggle()
                            try? modelContext.save()
                        } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(SnappetColor.wardrobe)
                                .padding(12)
                        }
                        .accessibilityIdentifier("wardrobe.item.favorite")
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.bold))
                    Text(addedLine)
                        .font(.caption)
                        .foregroundStyle(SnappetColor.textSecondary)
                }

                tagChips

                HStack(spacing: 8) {
                    statTile(value: "\(stats.wearCount)×", label: "Worn")
                    statTile(value: stats.lastWornAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "—",
                             label: "Last worn")
                    statTile(value: WearStats.costPerWearLabel(cost: item.cost, wears: stats.wearCount) ?? "—",
                             label: "Cost / wear")
                }

                HStack(spacing: 8) {
                    Button {
                        showGenerator = true
                    } label: {
                        Label("Style this", systemImage: "sparkles")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SnappetColor.wardrobe)
                    .accessibilityIdentifier("wardrobe.item.style")

                    NavigationLink {
                        StyleCoachView(item: item)
                    } label: {
                        Label("Ask coach", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wardrobe.item.coach")
                }
            }
            .padding(16)
        }
        .background(SnappetColor.paper)
        .navigationTitle("Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        logWear()
                    } label: {
                        Label("Log wear today", systemImage: "checkmark.circle")
                    }
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit details", systemImage: "pencil")
                    }
                    Button {
                        item.isArchived.toggle()
                        try? modelContext.save()
                        if item.isArchived { dismiss() }
                    } label: {
                        Label(item.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete item", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("wardrobe.item.menu")
            }
        }
        .sheet(isPresented: $showGenerator) {
            OutfitGeneratorView(buildAround: item)
        }
        .sheet(isPresented: $showEdit) {
            WardrobeItemEditSheet(item: item)
        }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete item", role: .destructive) {
                modelContext.delete(item)
                try? modelContext.save()
                dismiss()
            }
        } message: {
            Text("Its wear history stays in your stats. This can't be undone.")
        }
    }

    private var addedLine: String {
        var parts = ["Added \(item.createdAt.formatted(.dateTime.month(.abbreviated).year()))"]
        if let cost = item.cost {
            parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(0))))
        }
        return parts.joined(separator: " · ")
    }

    private var tagChips: some View {
        FlowChips(labels: chipLabels)
    }

    private var chipLabels: [String] {
        var out = [item.category.title, item.color.title]
        if item.pattern != .solid { out.append(item.pattern.title) }
        out.append(item.style.title)
        if !item.material.isEmpty { out.append(item.material) }
        if !item.seasons.isEmpty {
            out.append(item.seasons.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " · "))
        }
        return out
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold))
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.hairline))
    }

    private func logWear() {
        modelContext.insert(WearEvent(itemID: item.id))
        try? modelContext.save()
        core.log(module: "wardrobe", action: "wear", summary: "Wore \(item.name)")
    }
}

/// Simple wrapping chip row (tags never need more than two lines).
struct FlowChips: View {
    let labels: [String]

    var body: some View {
        FlexibleHStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(SnappetColor.wardrobe.opacity(0.1), in: Capsule())
                    .foregroundStyle(SnappetColor.wardrobe)
            }
        }
    }
}

/// Minimal wrapping layout for chips.
struct FlexibleHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Edit sheet: the same fields as capture, minus the photo pipeline.
struct WardrobeItemEditSheet: View {
    @Bindable var item: WardrobeItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var costText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $item.name)
                    Picker("Category", selection: $item.category) {
                        ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Color", selection: $item.color) {
                        ForEach(GarmentColorFamily.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Pattern", selection: $item.pattern) {
                        ForEach(GarmentPattern.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Style", selection: $item.style) {
                        ForEach(GarmentStyle.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Material", text: $item.material)
                    TextField("Cost", text: $costText)
                        .keyboardType(.decimalPad)
                }
                Section("Seasons — empty for all-season") {
                    HStack {
                        ForEach(GarmentSeason.allCases) { season in
                            let on = item.seasons.contains(season)
                            Button {
                                var s = item.seasons
                                if on { s.remove(season) } else { s.insert(season) }
                                item.seasons = s
                            } label: {
                                Text(season.title)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(on ? SnappetColor.wardrobe : SnappetColor.surfaceMuted, in: Capsule())
                                    .foregroundStyle(on ? .white : SnappetColor.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        item.cost = Double(costText.replacingOccurrences(of: ",", with: ".")) ?? item.cost
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                costText = item.cost.map { String(format: "%.0f", $0) } ?? ""
            }
        }
    }
}
