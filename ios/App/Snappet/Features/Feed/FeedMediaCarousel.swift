import SwiftUI

// MARK: - Recap Feed — in-card media carousel (F3b · R6)
//
// An Instagram-style, horizontally-paged carousel of ALL a session's clips, hosted inside the a1
// climb-session card (alongside R2's single inline-player hero). Each page is a STILL poster frame
// (reusing the browser's `ClipThumbnail` loader) — no inline players here, so the single-active-player
// discipline holds: only the R2 hero and the fullscreen viewer play video. Tapping a page opens the
// paged fullscreen viewer at that index; "View all" opens the grouped browser.
//
// Lightweight by design (it lives in a feed card): page dots, a "1/N" count badge, a slight peek of the
// next clip, and a per-clip name tag. The HR overlay + real playback are the fullscreen viewer's job.

struct FeedMediaCarousel: View {
    let clips: [MediaInput]
    let hrSeries: [HRPoint]
    let maxHR: Double
    /// Resolves a group key (`exerciseId` / `climbUUID` / "general") → display label for the name tag.
    let nameFor: (String) -> String
    /// The source card + the Animate context, threaded into the fullscreen viewer's Share/Animate.
    let card: FeedCard
    let clipContext: ClipExportCoordinator.Context?

    @State private var page = 0
    @State private var viewerIndex: Int?
    @State private var showingBrowser = false

    /// `offsetSec`-ordered (stable) so the carousel order matches the browser + the export ranking.
    private var ordered: [MediaInput] {
        clips.sorted { $0.offsetSec == $1.offsetSec ? $0.id.uuidString < $1.id.uuidString : $0.offsetSec < $1.offsetSec }
    }

    var body: some View {
        if ordered.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                carousel
                footer
            }
            .accessibilityIdentifier("feed.card.carousel")
            .fullScreenCover(item: $viewerIndex.asItem) { box in
                MediaBrowserView.viewer(clips: ordered, startIndex: box.value,
                                        hrSeries: hrSeries, maxHR: maxHR, nameFor: nameFor,
                                        card: card, clipContext: clipContext)
            }
            .sheet(isPresented: $showingBrowser) {
                MediaBrowserView(media: ordered, hrSeries: hrSeries, maxHR: maxHR, nameFor: nameFor,
                                 card: card, clipContext: clipContext)
            }
        }
    }

    /// The paged thumbnails. A slight horizontal inset shows a peek of the neighbouring page (IG-style),
    /// and the `TabView` page index drives the dots + badge below. Tapping a page → fullscreen at it.
    private var carousel: some View {
        TabView(selection: $page) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, clip in
                FeedClipPoster(clip: clip, name: tagName(clip), peakBpm: clipHR(clip).peakBpm,
                               zoneRaw: clipHR(clip).zoneRaw)
                    .padding(.horizontal, ordered.count > 1 ? 3 : 0)   // peek of the next page
                    // A page tap must open the fullscreen viewer, NOT the enclosing NavigationLink's
                    // card-detail nav. A plain `.onTapGesture` loses to the NavigationLink (the link
                    // wins the tap → CardDetailView). A `.highPriorityGesture` claims the tap first so
                    // the page reliably opens the pager. It's scoped to the poster only, so the card's
                    // double-tap-react / long-press-save on the rest of the card are untouched; the
                    // `.page` TabView still owns the horizontal paging swipe (vertical scroll passes
                    // through), so swiping the carousel doesn't trigger this tap.
                    .highPriorityGesture(TapGesture().onEnded { viewerIndex = idx })
                    .tag(idx)
                    .accessibilityIdentifier("feed.card.carousel.page")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))   // custom dots below instead of the OS dots
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: SnappetRadius.md, style: .continuous))
        .overlay(alignment: .topTrailing) { countBadge }
    }

    private var countBadge: some View {
        Text("\(min(page, ordered.count - 1) + 1)/\(ordered.count)")
            .font(.caption2.weight(.heavy)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
            .accessibilityIdentifier("feed.card.carousel.count")
    }

    private var footer: some View {
        HStack {
            if ordered.count > 1 {
                HStack(spacing: 5) {
                    ForEach(ordered.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? SnappetColor.kilter : SnappetColor.textSecondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityIdentifier("feed.card.carousel.dots")
            }
            Spacer()
            Button { showingBrowser = true } label: {
                Label("View all (\(ordered.count))", systemImage: "rectangle.grid.2x2")
                    .font(.caption2.weight(.semibold)).foregroundStyle(SnappetColor.kilter)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("feed.card.carousel.viewAll")
        }
    }

    private func clipHR(_ m: MediaInput) -> MediaClipHR {
        FeedMedia.clipHR(offsetSec: m.offsetSec, durationSec: m.durationSec, hrSeries: hrSeries, maxHR: maxHR)
    }

    private func tagName(_ m: MediaInput) -> String {
        nameFor(m.exerciseId?.uuidString ?? m.climbUUID ?? "general")
    }
}

/// One carousel page: the real PHAsset poster (reusing `ClipThumbnail`), a name tag, and a compact peak
/// chip — a STILL image, never an inline player (single-active discipline). Fills the card width.
private struct FeedClipPoster: View {
    let clip: MediaInput
    let name: String
    let peakBpm: Int?
    let zoneRaw: Int?

    var body: some View {
        ClipThumbnail(localIdentifier: clip.localIdentifier, kind: clip.kind,
                      size: CGSize(width: 320, height: 200))
            .overlay(alignment: .bottomLeading) {
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if let peakBpm {
                    Text("\(peakBpm)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(SnappetColor.performance(forZone: HeartRateZone(rawValue: zoneRaw ?? 0) ?? .none),
                                    in: Capsule())
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Int? ⇄ Identifiable box for `.fullScreenCover(item:)`

/// A tiny `Identifiable` wrapper so an `Int` start-index can drive `.fullScreenCover(item:)` (which
/// needs `Identifiable`). `Binding<Int?>.asItem` adapts the optional index to an item binding.
struct CarouselViewerBox: Identifiable, Equatable {
    let value: Int
    var id: Int { value }
}

extension Binding where Value == Int? {
    var asItem: Binding<CarouselViewerBox?> {
        Binding<CarouselViewerBox?>(
            get: { wrappedValue.map(CarouselViewerBox.init) },
            set: { wrappedValue = $0?.value })
    }
}
