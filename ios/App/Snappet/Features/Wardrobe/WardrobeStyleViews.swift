import SwiftUI
import SwiftData

// The "For You" surface + the custom generator + the flat-lay board (wardrobe prompt 01).
// All composition is `OutfitComposer` (pure); these views only join SwiftData rows into
// `GarmentProfile`s and render the result.

/// Joined closet snapshot the style surfaces share.
@MainActor
private func closetProfiles(items: [WardrobeItem], wearEvents: [WearEvent]) -> [GarmentProfile] {
    let stats = WearStats.byItem(wornItemIDs: wearEvents.compactMap { e in e.itemID.map { ($0, e.wornOn) } })
    return items.filter { !$0.isArchived }.map { i in
        i.profile(wearCount: stats[i.id]?.wearCount ?? 0, lastWornAt: stats[i.id]?.lastWornAt)
    }
}

// MARK: - For You

/// Daily pre-composed suggestions the user just picks from. Deterministic per day
/// (seeded by day-of-year) so the feed doesn't reshuffle every visit; the season/temp
/// header is a manual override stored per-launch (WeatherKit is a recorded follow-up).
struct ForYouView: View {
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]

    @State private var season: GarmentSeason = .forMonth(Calendar.current.component(.month, from: .now))
    @State private var tempBand: TempBand = .forSeason(.forMonth(Calendar.current.component(.month, from: .now)))
    @State private var showGenerator = false

    private var profiles: [GarmentProfile] { closetProfiles(items: items, wearEvents: wearEvents) }
    private var suggestions: [SuggestedOutfit] {
        OutfitComposer.forYou(items: profiles, season: season, tempBand: tempBand)
    }
    private var request: OutfitRequest {
        OutfitRequest(occasion: .casualWeekend, season: season, tempBand: tempBand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                weatherHeader

                if suggestions.isEmpty {
                    ContentUnavailableView("Not enough pieces yet", systemImage: "sparkles",
                        description: Text("Add a top, a bottom and shoes — suggestions appear here."))
                        .padding(.top, 30)
                } else {
                    ForEach(suggestions) { suggestion in
                        NavigationLink {
                            OutfitBoardView(initial: suggestion.outfit,
                                            request: request,
                                            title: suggestion.title)
                        } label: {
                            SuggestionCard(suggestion: suggestion, items: items)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wardrobe.forYou.card")
                    }
                    Text("Composed on-device from your closet, the season & your wear history.")
                        .font(.system(size: 10))
                        .foregroundStyle(SnappetColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }

                Button {
                    showGenerator = true
                } label: {
                    Label("Style me — custom occasion", systemImage: "sparkles")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.wardrobe)
                .padding(.top, 8)
                .accessibilityIdentifier("wardrobe.forYou.styleMe")
            }
            .padding(16)
            .padding(.bottom, 70)
        }
        .background(SnappetColor.paper)
        .sheet(isPresented: $showGenerator) {
            OutfitGeneratorView(buildAround: nil)
        }
    }

    private var weatherHeader: some View {
        HStack(spacing: 8) {
            Text(tempBand.emoji)
            Text("\(season.title) · \(tempBand.title)")
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
}

/// One For You card: title, the "why", and the piece thumbnails.
private struct SuggestionCard: View {
    let suggestion: SuggestedOutfit
    let items: [WardrobeItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(suggestion.title, systemImage: "sparkles")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(suggestion.reason)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            HStack(spacing: 8) {
                ForEach(suggestion.outfit.slots, id: \.itemID) { slot in
                    if let item = items.first(where: { $0.id == slot.itemID }) {
                        WardrobeItemTile(item: item, height: 52)
                            .frame(width: 52)
                    }
                }
                Spacer()
                Text("Open ›")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SnappetColor.wardrobe)
            }
        }
        .padding(12)
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
    }
}

// MARK: - Generator

/// The custom-occasion input sheet: occasion chips + season/temp + free text +
/// optional build-around piece → pushes the composed board.
struct OutfitGeneratorView: View {
    var buildAround: WardrobeItem?

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]

    @State private var occasion: OutfitOccasion = .work
    @State private var season: GarmentSeason = .forMonth(Calendar.current.component(.month, from: .now))
    @State private var tempBand: TempBand = .forSeason(.forMonth(Calendar.current.component(.month, from: .now)))
    @State private var note = ""
    @State private var composed: ComposedOutfit?
    @State private var noOutfit = false

    private var request: OutfitRequest {
        OutfitRequest(occasion: occasion, season: season, tempBand: tempBand,
                      note: note, buildAround: buildAround?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Occasion") {
                    FlexibleHStack(spacing: 6) {
                        ForEach(OutfitOccasion.allCases) { o in
                            Button {
                                occasion = o
                            } label: {
                                Text(o.title)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(occasion == o ? SnappetColor.wardrobe : SnappetColor.surfaceMuted,
                                                in: Capsule())
                                    .foregroundStyle(occasion == o ? .white : SnappetColor.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Weather") {
                    Picker("Season", selection: $season) {
                        ForEach(GarmentSeason.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Temperature", selection: $tempBand) {
                        ForEach(TempBand.allCases) { Text("\($0.emoji) \($0.title)").tag($0) }
                    }
                }
                Section("Anything else?") {
                    TextField("“client offsite, rooftop dinner after…”", text: $note)
                }
                if let buildAround {
                    Section("Built around") {
                        HStack(spacing: 10) {
                            WardrobeItemTile(item: buildAround, height: 44).frame(width: 44)
                            Text(buildAround.name).font(.subheadline.weight(.semibold))
                        }
                    }
                }
                Section {
                    Button {
                        let profiles = closetProfiles(items: items, wearEvents: wearEvents)
                        composed = OutfitComposer.compose(items: profiles, request: request)
                        noOutfit = composed == nil
                    } label: {
                        Label("Generate outfit", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SnappetColor.brand)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("wardrobe.generator.generate")
                    Text("Uses only items you own · composed on-device")
                        .font(.system(size: 10))
                        .foregroundStyle(SnappetColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Style me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(item: $composed) { outfit in
                OutfitBoardView(initial: outfit, request: request,
                                title: "\(occasion.title) · \(tempBand.title)")
            }
            .alert("No outfit possible yet", isPresented: $noOutfit) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The closet needs at least a top + bottom (or a dress) that fit this season.")
            }
        }
    }
}

// MARK: - Board

/// The flat-lay board: slot tiles with per-slot ⇄ swap, "why this works", and the three
/// actions — Shuffle (reseed), Save, Wear today (logs every piece's wear).
struct OutfitBoardView: View {
    var initial: ComposedOutfit
    var request: OutfitRequest
    var title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]
    @Query private var wearEvents: [WearEvent]

    @State private var outfit: ComposedOutfit?
    @State private var seed: UInt64 = 0
    @State private var saved = false

    private var current: ComposedOutfit { outfit ?? initial }
    private var profiles: [GarmentProfile] { closetProfiles(items: items, wearEvents: wearEvents) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(current.slots, id: \.itemID) { slot in
                        slotTile(slot)
                    }
                }

                if !current.rationale.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why this works").font(.caption.weight(.heavy)).foregroundStyle(SnappetColor.wardrobe)
                        ForEach(current.rationale, id: \.self) { line in
                            Text("· \(line)").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(SnappetColor.wardrobe.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SnappetColor.wardrobe.opacity(0.16)))
                }

                HStack(spacing: 8) {
                    Button {
                        seed &+= 1
                        var req = request
                        req.seed = seed
                        if let next = OutfitComposer.compose(items: profiles, request: req) { outfit = next }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wardrobe.board.shuffle")

                    Button {
                        saveOutfit(markWorn: false)
                    } label: {
                        Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(saved)
                    .accessibilityIdentifier("wardrobe.board.save")

                    Button {
                        saveOutfit(markWorn: true)
                        dismiss()
                    } label: {
                        Label("Wear today", systemImage: "tshirt")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SnappetColor.brand)
                    .accessibilityIdentifier("wardrobe.board.wear")
                }
            }
            .padding(16)
        }
        .background(SnappetColor.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func slotTile(_ slot: ComposedOutfit.Slot) -> some View {
        if let item = items.first(where: { $0.id == slot.itemID }) {
            VStack(alignment: .leading, spacing: 4) {
                WardrobeItemTile(item: item, height: 100)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            swap(slot)
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(SnappetColor.wardrobe)
                                .frame(width: 24, height: 24)
                                .background(SnappetColor.surface, in: Circle())
                                .overlay(Circle().strokeBorder(SnappetColor.hairline))
                        }
                        .padding(6)
                        .accessibilityIdentifier("wardrobe.board.swap")
                    }
                Text(slot.role.title.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(SnappetColor.textSecondary)
                Text(item.name)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .padding(10)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SnappetColor.hairline))
        }
    }

    private func swap(_ slot: ComposedOutfit.Slot) {
        let alternates = OutfitComposer.alternatives(for: slot.role, in: current,
                                                     items: profiles, request: request)
        guard let next = alternates.first else { return }
        var updated = current
        if let idx = updated.slots.firstIndex(of: slot) {
            updated.slots[idx] = .init(role: slot.role, itemID: next.id)
            outfit = updated
            saved = false
        }
    }

    private func saveOutfit(markWorn: Bool) {
        let record = WardrobeOutfit(title: title, occasion: request.occasion,
                                    tempBand: request.tempBand, season: request.season,
                                    rationale: current.rationale, slots: current.slots,
                                    lastWornAt: markWorn ? .now : nil,
                                    sourceRaw: request.buildAround == nil ? "forYou" : "custom")
        modelContext.insert(record)
        if markWorn {
            for slot in current.slots {
                modelContext.insert(WearEvent(itemID: slot.itemID, outfitID: record.id))
            }
        }
        try? modelContext.save()
        saved = true
        core.log(module: "wardrobe", action: markWorn ? "wear" : "save",
                 summary: markWorn ? "Wore outfit: \(title)" : "Saved outfit: \(title)",
                 metric: Double(current.slots.count))
    }
}
