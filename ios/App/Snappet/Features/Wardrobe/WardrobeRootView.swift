import SwiftUI
import SwiftData

/// The Wardrobe root: three surfaces (Closet · For You · Outfits) behind a module-local
/// glass bottom bar, pushed into the suite's NavigationStack (no stack of its own).
/// First-run shows the privacy-first empty state; capture is the single coral CTA.
struct WardrobeRootView: View {
    enum Surface: String, CaseIterable, Identifiable {
        case closet, forYou, outfits
        var id: String { rawValue }
        var title: String {
            switch self {
            case .closet: return "Closet"
            case .forYou: return "For You"
            case .outfits: return "Outfits"
            }
        }
        var systemImage: String {
            switch self {
            case .closet: return "hanger"
            case .forYou: return "sparkles"
            case .outfits: return "square.grid.2x2"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(SnappetCore.self) private var core
    @Query(sort: \WardrobeItem.createdAt, order: .reverse) private var items: [WardrobeItem]

    @State private var surface: Surface = .closet
    @State private var showCapture = false

    private var activeItems: [WardrobeItem] { items.filter { !$0.isArchived } }

    var body: some View {
        Group {
            if activeItems.isEmpty && surface == .closet {
                WardrobeEmptyState(onAdd: { showCapture = true },
                                   onSample: { WardrobeSampleCloset.seed(into: modelContext) })
            } else {
                switch surface {
                case .closet: ClosetView(showCapture: $showCapture)
                case .forYou: ForYouView()
                case .outfits: OutfitHistoryView()
                }
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
        .safeAreaInset(edge: .bottom) { surfaceBar }
        .sheet(isPresented: $showCapture) {
            WardrobeCaptureSheet()
        }
        .navigationDestination(for: WardrobeItem.self) { item in
            WardrobeItemDetailView(item: item)
        }
        .onAppear {
            core.log(module: "wardrobe", action: "open", summary: "Opened Wardrobe")
        }
    }

    private var surfaceBar: some View {
        HStack {
            ForEach(Surface.allCases) { s in
                Button {
                    surface = s
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: s.systemImage).font(.system(size: 18, weight: .semibold))
                        Text(s.title).font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(surface == s ? SnappetColor.wardrobe : SnappetColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wardrobe.tab.\(s.rawValue)")
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SnappetColor.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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
