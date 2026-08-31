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

    @State private var showGenerator = false
    @State private var showEdit = false
    @State private var showPhotos = false
    @State private var confirmDelete = false

    @Query private var allPhotos: [WardrobePhoto]

    private var photoCount: Int {
        (item.imageData == nil ? 0 : 1) + allPhotos.filter { $0.itemID == item.id }.count
    }

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
                // Swipeable when the garment has more than one photo (wardrobe prompt 04);
                // otherwise this renders exactly the prompt-03 hero, with no added chrome.
                WardrobePhotoCarousel(item: item, height: 240)
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

                if item.cost != nil || !item.productURL.isEmpty || item.currentPrice != nil {
                    WardrobePurchaseSection(item: item)
                }

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
                        showPhotos = true
                    } label: {
                        Label("Manage photos (\(photoCount))", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("wardrobe.item.managePhotos")
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit details", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("wardrobe.item.edit")
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
        .sheet(isPresented: $showPhotos) {
            WardrobePhotosView(item: item)
        }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete item", role: .destructive) {
                // Sweep the photo rows FIRST: the FK is a plain UUID with no SwiftData
                // relationship, so nothing cascades and they would be orphaned bytes that
                // never get reclaimed (wardrobe prompt 04).
                WardrobePhotoStore.deleteAll(forItem: item.id, in: modelContext)
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
            parts.append(cost.formatted(.currency(code: WearStats.localCurrencyCode)
                .precision(.fractionLength(0))))
        }
        return parts.joined(separator: " · ")
    }

    private var tagChips: some View {
        FlowChips(labels: chipLabels)
    }

    private var chipLabels: [String] {
        // `*Display`, not `.title`: the typed accessors resolve a CUSTOM value through its scoring
        // map, so `item.color.title` renders a user's "Mustard" as "Yellow". Scoring wants the
        // built-in; the chips want what the user typed.
        var out = [item.categoryDisplay, item.colorDisplay]
        if item.pattern != .solid { out.append(item.patternDisplay) }
        out.append(item.styleDisplay)
        if !item.brand.isEmpty { out.append(item.brand) }
        if !item.sizeLabel.isEmpty { out.append("Size \(item.sizeLabel)") }
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
///
/// Edits a local **draft**, not the live model: the old sheet bound fields straight to the
/// `@Model`, so every keystroke persisted immediately, Cancel was impossible, and a swipe-down
/// kept half-applied values *without* the Done-path normalization — the second door through
/// which `'Uniqlo '` re-entered the closet. Now nothing touches the item until Done.
struct WardrobeItemEditSheet: View {
    let item: WardrobeItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // The draft. Raw + map pairs (never the typed setters — a typed write clears the custom map
    // and overwrites the raw with a built-in, destroying a custom value like "Mustard").
    @State private var name = ""
    @State private var categoryRaw = ""
    @State private var categoryMapRaw = ""
    @State private var colorRaw = ""
    @State private var colorMapRaw = ""
    @State private var patternRaw = ""
    @State private var patternMapRaw = ""
    @State private var styleRaw = ""
    @State private var styleMapRaw = ""
    @State private var brand = ""
    @State private var sizeLabel = ""
    @State private var material = ""
    @State private var productURL = ""
    @State private var seasons: Set<GarmentSeason> = []
    @State private var costText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("wardrobe.edit.name")
                    // `WardrobeValueRow` (open) rather than a closed `Picker` — see the draft note
                    // above for why these bind raw + map, never the typed accessors.
                    WardrobeValueRow(field: .category, value: $categoryRaw,
                                     mapsToRaw: $categoryMapRaw,
                                     display: GarmentCategory(rawValue: categoryRaw)?.title)
                    WardrobeValueRow(field: .color, value: $colorRaw,
                                     mapsToRaw: $colorMapRaw,
                                     display: GarmentColorFamily(rawValue: colorRaw)?.title)
                    WardrobeValueRow(field: .pattern, value: $patternRaw,
                                     mapsToRaw: $patternMapRaw,
                                     display: GarmentPattern(rawValue: patternRaw)?.title)
                    WardrobeValueRow(field: .style, value: $styleRaw,
                                     mapsToRaw: $styleMapRaw,
                                     display: GarmentStyle(rawValue: styleRaw)?.title)
                }
                Section("Brand & fit") {
                    WardrobeValueRow(field: .brand, value: $brand,
                                     mapsToRaw: .constant(""), display: nil)
                    WardrobeValueRow(field: .size, value: $sizeLabel,
                                     mapsToRaw: .constant(""), display: nil)
                    WardrobeValueRow(field: .material, value: $material,
                                     mapsToRaw: .constant(""), display: nil)
                }
                Section("Purchase") {
                    TextField("Price paid", text: $costText)
                        .keyboardType(.decimalPad)
                    TextField("Product link", text: $productURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Seasons — empty for all-season") {
                    HStack {
                        ForEach(GarmentSeason.allCases) { season in
                            let on = seasons.contains(season)
                            Button {
                                if on { seasons.remove(season) } else { seasons.insert(season) }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("wardrobe.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                        .accessibilityIdentifier("wardrobe.edit.done")
                }
            }
            .onAppear(perform: load)
        }
    }

    /// Seed the draft from the item once. `onAppear` runs before first paint on a sheet, and the
    /// item can't change underneath an open modal, so a plain copy is enough.
    private func load() {
        name = item.name
        categoryRaw = item.categoryRaw; categoryMapRaw = item.categoryMapRaw
        colorRaw = item.colorRaw; colorMapRaw = item.colorMapRaw
        patternRaw = item.patternRaw; patternMapRaw = item.patternMapRaw
        styleRaw = item.styleRaw; styleMapRaw = item.styleMapRaw
        brand = item.brand
        sizeLabel = item.sizeLabel
        material = item.material
        productURL = item.productURL
        seasons = item.seasons
        // `%g`, not `%.0f`: the old seed rounded 49.99 → "50", so opening the sheet and tapping
        // Done silently rewrote the price.
        costText = item.cost.map { String(format: "%g", $0) } ?? ""
    }

    /// The one write path. Normalizes on the way out, exactly as capture does, and teaches the
    /// dropdowns — an edit is a teacher too, not just capture.
    private func commit() {
        item.name = name
        item.categoryRaw = categoryRaw; item.categoryMapRaw = categoryMapRaw
        item.colorRaw = colorRaw; item.colorMapRaw = colorMapRaw
        item.patternRaw = patternRaw; item.patternMapRaw = patternMapRaw
        item.styleRaw = styleRaw; item.styleMapRaw = styleMapRaw
        item.brand = WardrobeVocabularyRules.normalize(brand)
        item.sizeLabel = WardrobeVocabularyRules.normalize(sizeLabel)
        item.material = WardrobeVocabularyRules.normalize(material)
        item.productURL = productURL.trimmingCharacters(in: .whitespacesAndNewlines)
        item.seasons = seasons
        // Emptying the field clears the price; unparseable text keeps the old value.
        item.cost = costText.isEmpty
            ? nil : Double(costText.replacingOccurrences(of: ",", with: ".")) ?? item.cost
        try? modelContext.save()
        WardrobeVocabularyStore.remember(item.brand, field: .brand, in: modelContext)
        WardrobeVocabularyStore.remember(item.sizeLabel, field: .size, in: modelContext)
        WardrobeVocabularyStore.remember(item.material, field: .material, in: modelContext)
        dismiss()
    }
}
