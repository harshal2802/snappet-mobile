import SwiftUI
import AVKit
import Photos
import UIKit
import Combine

// MARK: - Recap Feed — session media browser + paged viewer (F3b · R6)
//
// Instagram-style browser of ALL a session's clips, grouped by exercise / session / All, each with a
// per-clip HR overlay + a name tag. Tiles show the real PHAsset poster frame; the full-screen viewer is
// a paged `TabView(.page)` that plays the actual clip on device (auto-play + loop), swipes between
// clips, and pins the EDITOR's `HRTileView` overlay over each (single HR source of truth — the same
// scorebug tile the R4 export burns, so preview == burn). Both degrade gracefully to a
// gradient/placeholder when the asset can't be resolved (deleted, not granted under limited Photos
// access, or the simulator, which has no library) — the structure stays verifiable either way.

struct MediaBrowserView: View {
    let media: [MediaInput]
    let hrSeries: [HRPoint]
    let maxHR: Double
    let nameFor: (String) -> String     // group key (exerciseId / climbUUID) → label
    let card: FeedCard
    let clipContext: ClipExportCoordinator.Context?

    @Environment(\.dismiss) private var dismiss
    @State private var grouping: FeedMedia.Grouping = .byExercise
    @State private var viewerIndex: CarouselViewerBox?

    /// `offsetSec`-ordered flat list — the index space the fullscreen viewer pages over (so a tap in any
    /// bucket opens at the right absolute clip).
    private var ordered: [MediaInput] { FeedMedia.ordered(media) }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Group", selection: $grouping) {
                    ForEach(FeedMedia.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding()

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(FeedMedia.groups(media, by: grouping, nameFor: nameFor)) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                                Spacer()
                                Text("\(group.items.count) clip\(group.items.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(group.items) { item in
                                        tile(item).onTapGesture { open(item) }
                                    }
                                }
                            }
                        }
                    }
                    if media.isEmpty {
                        ContentUnavailableView("No clips", systemImage: "video.slash",
                                               description: Text("Media shot during a session shows up here."))
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, SnappetSpacing.lg)
            }
            .background(SnappetColor.paper)
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewerIndex) { box in
                Self.viewer(clips: ordered, startIndex: box.value,
                            hrSeries: hrSeries, maxHR: maxHR, nameFor: nameFor,
                            card: card, clipContext: clipContext)
            }
        }
        .accessibilityIdentifier("feed.media")
    }

    /// Open the fullscreen pager at the tapped clip's ABSOLUTE index in the offset-ordered list.
    private func open(_ m: MediaInput) {
        if let idx = ordered.firstIndex(where: { $0.id == m.id }) { viewerIndex = CarouselViewerBox(value: idx) }
    }

    /// The fullscreen paged viewer — the single entry point used by both the carousel and the browser.
    @ViewBuilder
    static func viewer(clips: [MediaInput], startIndex: Int, hrSeries: [HRPoint], maxHR: Double,
                       nameFor: @escaping (String) -> String, card: FeedCard,
                       clipContext: ClipExportCoordinator.Context?) -> some View {
        PagedMediaViewer(clips: clips, startIndex: startIndex, hrSeries: hrSeries, maxHR: maxHR,
                         nameFor: nameFor, card: card, clipContext: clipContext,
                         restHR: clipContext?.restHR)
    }

    /// The SAME fullscreen paged player, presented WITHOUT the Recap Share/Animate affordance (no
    /// `FeedCard`) — the Clips feed's tap-to-play (prompt 83). The HR overlay slices the session HR with
    /// the session `restHR` (matching the in-feed poster), so the fullscreen scorebug == the poster's.
    @ViewBuilder
    static func clipsViewer(clips: [MediaInput], startIndex: Int, hrSeries: [HRPoint], maxHR: Double,
                            restHR: Double?, nameFor: @escaping (String) -> String) -> some View {
        PagedMediaViewer(clips: clips, startIndex: startIndex, hrSeries: hrSeries, maxHR: maxHR,
                         nameFor: nameFor, card: nil, clipContext: nil, restHR: restHR)
    }

    private func clipHR(_ m: MediaInput) -> MediaClipHR {
        FeedMedia.clipHR(offsetSec: m.offsetSec, durationSec: m.durationSec, hrSeries: hrSeries, maxHR: maxHR)
    }

    private func tagName(_ m: MediaInput) -> String { FeedMedia.tagName(m, nameFor: nameFor) }

    private func tile(_ m: MediaInput) -> some View {
        let hr = clipHR(m)
        return ZStack(alignment: .topTrailing) {
            ClipThumbnail(localIdentifier: m.localIdentifier, kind: m.kind, size: CGSize(width: 104, height: 138))
                .overlay(alignment: .bottomLeading) {
                    Text(tagName(m)).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: Capsule())     // legible over a photo
                        .padding(6)
                }
            if let peak = hr.peakBpm {
                Text("\(peak)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(SnappetColor.performance(forZone: HeartRateZone(rawValue: hr.zoneRaw ?? 0) ?? .none), in: Capsule())
                    .padding(6)
            }
        }
        .accessibilityIdentifier("feed.media.tile")
    }
}

// MARK: - Poster-frame thumbnail (real PHAsset, graceful fallback)

/// Loads the asset's poster frame through one shared `PHCachingImageManager` (so scrolling the
/// carousel doesn't re-decode), falling back to the brand gradient + kind icon when the asset can't
/// be read (limited access, iCloud-only with network off, or the simulator). Mirrors the proven
/// `HighlightThumbnail` loader in ReelView. Shared by the in-card carousel + the browser tiles.
struct ClipThumbnail: View {
    let localIdentifier: String
    let kind: String
    let size: CGSize
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [SnappetColor.kilter.opacity(0.5), .black], startPoint: .top, endPoint: .bottom)
            }
            Image(systemName: kind == "video" ? "play.circle.fill" : "photo")
                .font(.title2).foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 4)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .task(id: localIdentifier) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        if let loaded = await AssetPosterLoader.poster(localIdentifier: localIdentifier, pointSize: size) {
            image = loaded
        }
    }
}

// MARK: - Full-screen paged clip viewer (real on-device playback + editor HR overlay)

/// Instagram-post grammar: a full-bleed paged `TabView(.page)` over the offset-ordered clips. Only the
/// centered page PLAYS its `AVPlayer` (single-active discipline carried from R2); off-center pages are
/// paused, not torn down — the active ±1 neighbours that `TabView(.page)` keeps resident stay warm so a
/// swipe resumes instantly (full teardown happens on the page's `.onDisappear`). Each page pins the
/// EDITOR's `HRTileView` overlay (built from the clip's HR window) + a name tag, and offers
/// Share/Animate, which present `ShareComposerView(card:clipContext:)` (R3/R4).
private struct PagedMediaViewer: View {
    let clips: [MediaInput]
    let startIndex: Int
    let hrSeries: [HRPoint]
    let maxHR: Double
    let nameFor: (String) -> String
    /// `nil` presents the player WITHOUT the Recap Share/Animate affordance (the Clips feed, prompt 83
    /// — it has no `FeedCard` and Share is out of slice). Recap passes its card.
    let card: FeedCard?
    let clipContext: ClipExportCoordinator.Context?
    /// Rest HR for the overlay's %HRR. Recap passes `clipContext?.restHR`; Clips passes the session's
    /// `restHR` directly (it has no `clipContext`).
    let restHR: Double?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var showingShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                    MediaPage(item: clip,
                              overlay: overlay(for: clip),
                              name: tagName(clip),
                              isActive: i == index)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            chrome
        }
        .accessibilityIdentifier("feed.media.viewer")
        .onAppear { index = min(max(0, startIndex), max(0, clips.count - 1)) }
        .sheet(isPresented: $showingShare) {
            if let card { ShareComposerView(card: card, clipContext: clipContext) }
        }
    }

    /// Top bar (name + count + close) and the bottom Share/Animate actions, over a legibility scrim.
    private var chrome: some View {
        VStack {
            HStack {
                Label(name, systemImage: currentKind == "video" ? "video.fill" : "photo.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                if clips.count > 1 {
                    Text("\(min(index, clips.count - 1) + 1)/\(clips.count)")
                        .font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                    .accessibilityIdentifier("feed.media.close")
            }
            Spacer()
            // Share/Animate only when presented from a Recap card; the Clips feed (card == nil) plays
            // without it — Share is out of the Clips slice (prompt 83).
            if card != nil {
                HStack(spacing: 12) {
                    Spacer()
                    Button { showingShare = true } label: {
                        Label(clipContext != nil ? "Animate" : "Share",
                              systemImage: clipContext != nil ? "wand.and.stars" : "square.and.arrow.up")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(SnappetColor.kilter, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed.media.share")
                }
            }
        }
        .padding(22)
    }

    private var name: String { clips.indices.contains(index) ? tagName(clips[index]) : "" }
    private var currentKind: String { clips.indices.contains(index) ? clips[index].kind : "video" }

    private func tagName(_ m: MediaInput) -> String { FeedMedia.tagName(m, nameFor: nameFor) }

    /// The clip's HR overlay — via the ONE `ClipHROverlay` mapping the poster, the inline player, and this
    /// viewer all share, so the fullscreen scorebug can't drift from the in-feed poster. `nil` when the clip
    /// has no HR in its window → the page degrades to the name tag only (no empty chart).
    private func overlay(for m: MediaInput) -> ClipHROverlay.Payload? {
        ClipHROverlay.make(clip: m, hrSeries: hrSeries, maxHR: maxHR, restHR: restHR)
    }
}

/// One fullscreen page: the real clip playback (active page only) under the editor HR overlay + name
/// tag. Reuses the `StudioPlayerLayerView`/PHAsset→AVPlayerItem path. Single-active rule: only the centered
/// page PLAYS; when a page de-centers it's PAUSED (not torn down) so its player + looper stay resident
/// and a swipe back resumes instantly. The player is fully released (paused, nilled, looper dropped)
/// only when the page leaves the `TabView`'s resident set — its `.onDisappear`.
private struct MediaPage: View {
    let item: MediaInput
    let overlay: ClipHROverlay.Payload?
    let name: String
    let isActive: Bool

    private enum LoadState: Equatable { case loading, ready, failed }

    @State private var state: LoadState = .loading
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?   // retained or looping stops
    @State private var image: UIImage?
    /// Live HR playhead (prompt 84): the playing clip's video time → `ClipHROverlay.fraction`, driving the
    /// scorebug's live BPM + chart dot in sync with the video. `1.0` = the clip's at-end reading, shown
    /// before play / when paused-by-de-center / for a photo (matching the still poster). Polled from the
    /// player by `ticker` (cleaner under Swift-6 than capturing this struct in an `addPeriodicTimeObserver`
    /// closure); ~0.12s = a smooth dot at a light re-render cost.
    @State private var playbackFraction: Double = ClipHROverlay.atEndFraction
    @State private var ticker = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black
            mediaLayer.ignoresSafeArea()

            // Scrim so the title + HR overlay stay legible over bright footage.
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                .allowsHitTesting(false)

            // The EDITOR overlay — the SAME scorebug HRTile the export burns (WYSIWYG). The tile is a
            // COMPACT card with NORMALIZED geometry (centerX/centerY/width/height, e.g. scorebug =
            // 0.92×0.27 at (0.50, 0.86)); size + position it at that fraction of the page exactly as the
            // export composites it onto the canvas. (Filling the whole page made HRTileLayout explode —
            // full-height zone bars + truncated "5…"/"B…".) `playbackFraction` sweeps the live BPM + chart
            // dot in step with the video (1.0 = the clip's at-end reading while not playing); nil → name tag.
            if let overlay {
                GeometryReader { geo in
                    HRTileView(tile: overlay.tile, values: overlay.values, fraction: playbackFraction)
                        .frame(width: geo.size.width * overlay.tile.width,
                               height: geo.size.height * overlay.tile.height)
                        .position(x: geo.size.width * overlay.tile.centerX,
                                  y: geo.size.height * overlay.tile.centerY)
                }
                .allowsHitTesting(false)
                .accessibilityIdentifier("feed.media.hrTile")
            }
        }
        .accessibilityIdentifier("feed.media.page")
        .task(id: item.id) { await load() }
        // Single-active: the centered page plays; a de-centered (but still resident) page PAUSES and resets
        // its HR playhead to the at-end reading (so a glimpsed off-center overlay isn't frozen mid-sweep).
        .onChange(of: isActive) { _, active in
            if active { player?.play() } else { player?.pause(); playbackFraction = ClipHROverlay.atEndFraction }
        }
        // Full teardown happens only when the page leaves the TabView's resident set (pause + nil player
        // + drop looper) — not on every de-center, so neighbouring pages stay warm by design.
        .onDisappear { teardown() }
        // Live HR (prompt 84): while THIS centered page's video is actually playing, sweep the scorebug
        // playhead in step with the video via the shared `ClipHROverlay.fraction`. Off-center / paused /
        // photo / no-HR pages take the guarded early return (near-zero cost) — only the active player ticks.
        .onReceive(ticker) { _ in
            guard isActive, item.kind == "video", let player, player.rate != 0, let overlay else { return }
            playbackFraction = ClipHROverlay.fraction(videoTime: player.currentTime().seconds,
                                                      clip: item, payload: overlay)
        }
    }

    @ViewBuilder private var mediaLayer: some View {
        if state == .loading {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == "video", let player {
            StudioPlayerLayerView(player: player, backgroundColor: .black)
                .accessibilityIdentifier("feed.media.player")
                .onTapGesture { player.rate == 0 ? player.play() : player.pause() }
        } else if let image {
            Image(uiImage: image).resizable().scaledToFit()
                .accessibilityIdentifier("feed.media.photo")
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: item.kind == "video" ? "play.slash" : "photo")
                .font(.system(size: 56)).foregroundStyle(.white.opacity(0.85))
            Text("Couldn’t load this clip").font(.caption).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("feed.media.placeholder")
    }

    private func teardown() { player?.pause(); player = nil; looper = nil }

    private func load() async {
        teardown()
        state = .loading
        image = nil
        playbackFraction = ClipHROverlay.atEndFraction   // the at-end reading until the video actually plays

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil)
        guard let asset = assets.firstObject else { state = .failed; return }

        if item.kind == "video" {
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true             // allow iCloud-stored clips to download
            opts.deliveryMode = .automatic
            // AVPlayerItem isn't Sendable → box it to cross the continuation boundary (mirrors ReelExporter).
            let boxed: Box<AVPlayerItem?> = await withCheckedContinuation { cont in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { pItem, _ in
                    cont.resume(returning: Box(pItem))
                }
            }
            guard let playerItem = boxed.value else { state = .failed; return }
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: playerItem)   // seamless loop
            player = queue
            state = .ready
            if isActive { queue.play() }                   // single-active: only the centered page plays
        } else {
            let target = CGSize(width: 1080, height: 1920)
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = true
            let loaded: UIImage? = await withCheckedContinuation { cont in
                PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                      contentMode: .aspectFit, options: opts) { img, _ in
                    cont.resume(returning: img)
                }
            }
            guard let loaded else { state = .failed; return }
            image = loaded
            state = .ready
        }
    }
}

/// Wraps a non-Sendable value so it can cross an async continuation boundary.
/// Safe here: each boxed value is produced and consumed exactly once, serially.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension HRTile {
    /// The feed clip's scorebug tile — the SAME `.scorebug` the export burns, but with HRR (heart-rate
    /// reserve) dropped when the session has no resting HR. HRR is undefined without a rest HR and would
    /// otherwise render a dead "0%". Used by BOTH the in-app viewer overlay and the export burn so they
    /// stay identical (WYSIWYG). The studio editor's own tiles are unaffected (they still use `.make`).
    static func feedClipScorebug(restHR: Double?) -> HRTile {
        var tile = HRTile.make(template: .scorebug)
        if (restHR ?? 0) <= 0 {
            tile.entries = tile.entries.map { entry in
                var entry = entry
                if entry.metric == .hrr { entry.on = false }
                return entry
            }
        }
        return tile
    }
}
