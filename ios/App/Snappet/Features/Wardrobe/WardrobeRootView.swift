import SwiftUI
import SwiftData

/// Which full-screen section a home tile pushes into (`WardrobeSectionsView`).
enum WardrobeSection: String, CaseIterable, Identifiable, Hashable {
    case closet, forYou, outfits
    var id: String { rawValue }
    var title: String {
        switch self {
        case .closet: return "Closet"
        case .forYou: return "For You"
        case .outfits: return "Outfits"
        }
    }
}

/// The Wardrobe root — the STYLIST-FIRST HOME (nav redesign, wardrobe prompt 02):
/// one scrolling landing with For You leading, a closet preview, and recent outfits;
/// "See all ›" pushes `WardrobeSectionsView`. No module-local bottom bar — the original
/// glass bar stacked on the suite tab bar (the double-chrome complaint); everything
/// here is reach or push, like the Kilter landing page.
struct WardrobeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]
    @Query(sort: \WardrobeOutfit.createdAt, order: .reverse) private var outfits: [WardrobeOutfit]

    @State private var showCapture = false
    @State private var showGenerator = false
    /// One-time photo reclaim for closets captured before wardrobe prompt 03. Driven from here
    /// rather than app launch so a user who never opens Wardrobe never pays for it.
    @State private var imageMigration = WardrobeImageMigration()
    @State private var migrationDismissed = false
    @State private var season: GarmentSeason = .forMonth(Calendar.current.component(.month, from: .now))
    @State private var tempBand: TempBand = .forSeason(.forMonth(Calendar.current.component(.month, from: .now)))

    private var activeItems: [WardrobeItem] { items.filter { !$0.isArchived } }

    private var stats: [UUID: WearStats.ItemStats] {
        WearStats.byItem(wornItemIDs: wearEvents.compactMap { e in e.itemID.map { ($0, e.wornOn) } })
    }

    private var profiles: [GarmentProfile] {
        activeItems.map { i in
            i.profile(wearCount: stats[i.id]?.wearCount ?? 0, lastWornAt: stats[i.id]?.lastWornAt)
        }
    }

    private var suggestions: [SuggestedOutfit] {
        OutfitComposer.forYou(items: profiles, season: season, tempBand: tempBand)
    }

    private var request: OutfitRequest {
        OutfitRequest(occasion: .casualWeekend, season: season, tempBand: tempBand)
    }

    var body: some View {
        Group {
            if activeItems.isEmpty {
                WardrobeEmptyState(onAdd: { showCapture = true },
                                   onSample: { WardrobeSampleCloset.seed(into: modelContext) })
            } else {
                home
            }
        }
        .navigationTitle("Wardrobe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    WardrobeSettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("wardrobe.settings")
            }
        }
        .sheet(isPresented: $showCapture) {
            WardrobeCaptureSheet()
        }
        .sheet(isPresented: $showGenerator) {
            OutfitGeneratorView(buildAround: nil)
        }
        .navigationDestination(for: WardrobeItem.self) { item in
            WardrobeItemDetailView(item: item)
        }
        .navigationDestination(for: WardrobeSection.self) { section in
            WardrobeSectionsView(initial: section)
        }
        .onAppear {
            core.log(module: "wardrobe", action: "open", summary: "Opened Wardrobe")
        }
        .onAppear {
            // `start`, not `.task { await … }`: SwiftUI cancels a `.task` when the view
            // disappears, so pushing "See all ›" into the closet killed the run partway (31 of
            // 100 on-device). `start` owns an unstructured task that outlives the navigation.
            // Self-gating: with nothing over the policy cap it costs one fetch and returns,
            // which is what makes it self-healing after a backup restore (masters come back,
            // thumbnails don't — by design).
            imageMigration.start(in: modelContext)
        }
    }

    // MARK: - The stylist-first home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !migrationDismissed {
                    WardrobeMigrationBanner(phase: imageMigration.phase) { migrationDismissed = true }
                        .padding(.top, 4)
                }

                weatherHeader

                // ✨ For You — the differentiator leads.
                HStack(alignment: .firstTextBaseline) {
                    Label("For You", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Button("Style me ›") { showGenerator = true }
                        .font(.caption.weight(.bold))
                        .tint(SnappetColor.wardrobe)
                        .accessibilityIdentifier("wardrobe.home.styleMe")
                }
                .padding(.top, 8)

                if suggestions.isEmpty {
                    Text("Add a top, a bottom and shoes — daily outfit ideas appear here.")
                        .font(.caption)
                        .foregroundStyle(SnappetColor.textSecondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(suggestions) { suggestion in
                                NavigationLink {
                                    OutfitBoardView(initial: suggestion.outfit,
                                                    request: request,
                                                    title: suggestion.title)
                                } label: {
                                    HomeSuggestionCard(suggestion: suggestion, items: activeItems)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("wardrobe.forYou.card")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollClipDisabled()
                }

                // Closet preview.
                sectionHeader("Closet · \(activeItems.count)", section: .closet,
                              identifier: "wardrobe.home.seeAllCloset")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(activeItems.prefix(4)) { item in
                        NavigationLink(value: item) {
                            ClosetItemCard(item: item, stats: fullStats(for: item))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Recent outfits.
                if !outfits.isEmpty {
                    sectionHeader("Outfits", section: .outfits,
                                  identifier: "wardrobe.home.seeAllOutfits")
                    ForEach(outfits.prefix(2)) { outfit in
                        HomeOutfitRow(outfit: outfit, items: activeItems)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 76)
        }
        .background(SnappetColor.paper)
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
            .accessibilityIdentifier("wardrobe.home.add")
        }
    }

    private func sectionHeader(_ title: String, section: WardrobeSection, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            NavigationLink(value: section) {
                Text("See all ›")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SnappetColor.wardrobe)
            }
            .accessibilityIdentifier(identifier)
        }
        .padding(.top, 14)
    }

    private var weatherHeader: some View {
        HStack(spacing: 8) {
            Text(tempBand.emoji)
            Text("\(Date.now.formatted(.dateTime.weekday(.wide))) · \(season.title) · \(tempBand.title)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Picker("Season", selection: $season) {
                    ForEach(GarmentSeason.allCases) { Text($0.title).tag($0) }
                }
                Picker("Temperature", selection: $tempBand) {
                    ForEach(TempBand.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Text("Adjust")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SnappetColor.wardrobe)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.hairline))
    }

    private func fullStats(for item: WardrobeItem) -> WearStats.ItemStats {
        var s = stats[item.id] ?? .init()
        if let cost = item.cost {
            s.costPerWear = WearStats.costPerWear(cost: cost, wears: s.wearCount)
        }
        return s
    }
}

/// Compact For You card for the home carousel (fixed width, swipeable).
private struct HomeSuggestionCard: View {
    let suggestion: SuggestedOutfit
    let items: [WardrobeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(suggestion.title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            Text(suggestion.reason)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SnappetColor.textSecondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                ForEach(suggestion.outfit.slots.prefix(4), id: \.itemID) { slot in
                    if let item = items.first(where: { $0.id == slot.itemID }) {
                        WardrobeItemTile(item: item, height: 44)
                            .frame(width: 44)
                    }
                }
                Spacer(minLength: 4)
                Text("Wear ›")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(SnappetColor.wardrobe)
            }
        }
        .padding(11)
        .frame(width: 236, alignment: .leading)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
    }
}

/// One recent-outfit row on the home (thumbnails + wear again handled on the full screen).
private struct HomeOutfitRow: View {
    let outfit: WardrobeOutfit
    let items: [WardrobeItem]

    var body: some View {
        NavigationLink(value: WardrobeSection.outfits) {
            HStack(spacing: 8) {
                ForEach(outfit.itemIDs.prefix(4), id: \.self) { id in
                    if let item = items.first(where: { $0.id == id }) {
                        WardrobeItemTile(item: item, height: 40)
                            .frame(width: 40)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(outfit.title.isEmpty ? outfit.occasion.title : outfit.title)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text((outfit.lastWornAt ?? outfit.createdAt).formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(SnappetColor.textSecondary)
                }
                .padding(.leading, 2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            .padding(10)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// The pushed full-screen container: Closet / For You / Outfits behind ONE segmented
/// control (the A-side of the approved A+B hybrid — quick jumps without popping home).
struct WardrobeSectionsView: View {
    @State private var section: WardrobeSection
    @State private var showCapture = false

    init(initial: WardrobeSection) {
        _section = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(WardrobeSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .accessibilityIdentifier("wardrobe.sections.picker")

            switch section {
            case .closet: ClosetView(showCapture: $showCapture)
            case .forYou: ForYouView()
            case .outfits: OutfitHistoryView()
            }
        }
        .background(SnappetColor.paper)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCapture) {
            WardrobeCaptureSheet()
        }
    }
}

/// First-run: the privacy pitch IS the marketing. One coral CTA + the sample-closet path.
private struct WardrobeEmptyState: View {
    var onAdd: () -> Void
    var onSample: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("👕👖👟").font(.system(size: 56)).padding(.top, 40)
                Text("Build your closet")
                    .font(.title2.weight(.bold))
                Text("Snap each piece once. Snappet tags it automatically — all on this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(SnappetColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)

                Button(action: onAdd) {
                    Label("Add your first item", systemImage: "camera")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("wardrobe.empty.add")

                Button("Try a sample closet", action: onSample)
                    .font(.subheadline.weight(.semibold))
                    .tint(SnappetColor.wardrobe)
                    .accessibilityIdentifier("wardrobe.empty.sample")

                VStack(alignment: .leading, spacing: 10) {
                    privacyRow("lock.fill", bold: "No account, no cloud.",
                               rest: "Your wardrobe is stored only on this device.")
                    privacyRow("sparkles", bold: "On-device AI.",
                               rest: "Tagging & styling run with Apple Intelligence, offline.")
                    privacyRow("icloud", bold: "Suite backup covers it.",
                               rest: "Wardrobe rides the Snappet backup file you already control.")
                }
                .padding(14)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
                .padding(.top, 14)
                .padding(.horizontal, 22)
            }
            .frame(maxWidth: .infinity)
        }
        .background(SnappetColor.paper)
    }

    private func privacyRow(_ symbol: String, bold: String, rest: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(SnappetColor.wardrobe)
                .frame(width: 20)
            Text("\(Text(bold).bold()) \(rest)")
                .font(.caption)
                .foregroundStyle(SnappetColor.textSecondary)
        }
    }
}
