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

    /// The Clips-feed fullscreen viewer (prompt 94): the paged player + the HR overlay (the session's
    /// WYSIWYG `tile`) + the play/pause + scrubber transport — no Recap card / Share.
    @ViewBuilder
    static func clipsViewer(clips: [MediaInput], startIndex: Int, hrSeries: [HRPoint], maxHR: Double,
                            restHR: Double?, nameFor: @escaping (String) -> String, tile: HRTile?) -> some View {
        PagedMediaViewer(clips: clips, startIndex: startIndex, hrSeries: hrSeries, maxHR: maxHR,
                         nameFor: nameFor, card: nil, clipContext: nil, restHR: restHR,
                         hrTile: tile, transport: true)
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
    /// Whether to actually REQUEST the poster bitmap. The Clips carousel windows this to pages near the
    /// current one (prompt 106) so a 50-clip post doesn't fire 50 concurrent frame-0 decodes on mount;
    /// the view renders its placeholder gradient until enabled. Defaulted so other callers (grid, Recap
    /// carousel, browser strip — all row-lazy already) are unchanged.
    var enabled: Bool = true
    /// The poster timestamp (seconds into the asset) — a Studio-trimmed clip passes its kept-range
    /// start (prompt 116) so the still equals the first frame the trimmed player displays.
    var posterTime: Double = 0
    @State private var image: UIImage?
    /// The (identifier, time) the current `image` was loaded for — so an enabled-flag flip doesn't
    /// re-decode a loaded poster, but a re-trim (new `posterTime`) does.
    @State private var loadedKey: String = ""

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
        // Keyed on `enabled` + `posterTime` too, so a page entering the load window (or a re-trim)
        // re-fires the (previously no-op) task.
        .task(id: "\(enabled)-\(localIdentifier)-\(Int(posterTime * 100))") { await load() }
    }

    private func load() async {
        let key = "\(localIdentifier)-\(Int(posterTime * 100))"
        guard enabled, image == nil || loadedKey != key else { return }
        // Video: use the EXACT first played frame (not Photos' arbitrary thumbnail) so the still equals
        // the frame the player layer first displays → the carousel's poster→video reveal is invisible
        // (no takeover flick). Photos keep the thumbnail; the frame path falls back to `poster(...)`.
        let loaded = kind == "video"
            ? await AssetPosterLoader.videoFrameZero(localIdentifier: localIdentifier, pointSize: size, at: posterTime)
            : await AssetPosterLoader.poster(localIdentifier: localIdentifier, pointSize: size)
        if let loaded { image = loaded; loadedKey = key }
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
    /// The session's SAVED Studio HR tile (WYSIWYG, prompt 89/94) so the fullscreen overlay matches the
    /// Clips poster; nil keeps the house-style scorebug (the Recap path).
    var hrTile: HRTile? = nil
    /// Clips fullscreen (prompt 94): show the play/pause + scrubber transport bar + take the audio session.
    var transport: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var showingShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                    MediaPage(item: clip, overlay: overlay(for: clip), isActive: i == index, transport: transport)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            chrome
        }
        .accessibilityIdentifier("feed.media.viewer")
        .onAppear {
            index = min(max(0, startIndex), max(0, clips.count - 1))
            if transport { ClipAudioSession.activate() }       // Clips fullscreen plays over the silent switch
        }
        .onDisappear { if transport { ClipAudioSession.deactivate() } }
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
        ClipHROverlay.make(clip: m, hrSeries: hrSeries, maxHR: maxHR, restHR: restHR, tile: hrTile)
    }
}

/// One fullscreen page: the editor HR scorebug + scrim over the shared `ClipMediaSurface` (which owns the
/// player/looper/photo + the live-HR playhead). Single-active: only the centered page's surface plays. The
/// name + Share chrome is the parent `PagedMediaViewer`'s; this page is just the media + the scorebug.
private struct MediaPage: View {
    let item: MediaInput
    let overlay: ClipHROverlay.Payload?
    let isActive: Bool
    /// Clips fullscreen (prompt 94): play/pause + scrubber transport over a non-looping player (video only).
    var transport: Bool = false
    /// Live HR playhead, written by `ClipMediaSurface` from the player and read by the scorebug below.
    @State private var playbackFraction: Double = ClipHROverlay.atEndFraction
    /// Drives the transport bar; the active video surface attaches its player to it.
    @State private var controller = ClipPlaybackController()

    private var transportActive: Bool { transport && item.kind == "video" }

    var body: some View {
        ZStack {
            Color.black
            // One shared media engine (player/looper/photo + the live-HR playhead) for both surfaces.
            ClipMediaSurface(clip: item, isActive: isActive, payload: overlay,
                             fraction: $playbackFraction, background: .black,
                             controller: transportActive ? controller : nil)
                .ignoresSafeArea()
                // Park the initial/at-rest playhead at the payload's footage boundary (prompt 116) —
                // the @State default can't consult the payload.
                .onAppear { playbackFraction = ClipHROverlay.atEnd(for: overlay) }

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

            // Play/pause + scrubbable timeline + mute (Clips fullscreen, prompt 94) — only on the active
            // video page, over the non-looping player it attached to `controller`.
            if transportActive, isActive {
                VStack {
                    Spacer()
                    MediaTransportBar(controller: controller).padding(.bottom, 28)
                }
            }
        }
        .accessibilityIdentifier("feed.media.page")
    }
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
