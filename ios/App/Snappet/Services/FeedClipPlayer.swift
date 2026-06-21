import SwiftUI
import AVFoundation
import Photos
import UIKit

// MARK: - Recap Feed — inline auto-clip hero player (F3, device)
//
// The DEVICE half of F3's media-first hero (R1 shipped the pure half: `FeedClipEligibility`,
// `FeedHeroResolver`, `FeedActivePlayerCoordinator`). This is a thin, self-contained SwiftUI view
// that plays ONE clip segment — MUTED + LOOPED over a time range — as a session card's hero, and
// degrades honestly to a still poster / generated hero when the asset can't be resolved (limited
// Photos access, iCloud-only with no network, or the simulator, which has no library).
//
// Single-active-player rule lives in the parent (`FeedView` feeds the R1 coordinator → one
// `isCentral` card → one `FeedClipPlayer` ever attaches an `AVPlayer`). This view just owns the
// lifecycle of its OWN single player and tears it down on disappear, so at most one is alive.
//
// Player I/O stays here in `Services/` (layering rule); `HighlightEngine` stays AVFoundation-free.
// Mirrors the proven `ClipPlayerLayer`/`PlayerContainerView`/`Box` pattern in MediaBrowserView —
// kept self-contained here (R6 consolidates the two surfaces); MediaBrowserView is untouched.

/// Plays the top-ranked clip segment of a session as a muted, looping hero. Resolve a `FeedClipRef`
/// (assetId + offsetSec + durationSec) → an `AVPlayerItem` via `PHImageManager` (muted), then loop
/// `CMTimeRange(start: offsetSec, duration: durationSec)` with `AVQueuePlayer` + `AVPlayerLooper`.
struct FeedClipPlayer: View {
    let clip: FeedClipRef

    private enum LoadState: Equatable { case loading, playing, poster, failed }

    @State private var state: LoadState = .loading
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?     // retained or looping stops
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            switch state {
            case .loading:
                // While the asset resolves, hold the brand gradient so the slot never flashes empty.
                gradient
                    .overlay(ProgressView().tint(.white))
            case .playing:
                if let player {
                    ClipHeroLayer(player: player)
                } else {
                    gradient
                }
            case .poster:
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    gradient
                }
            case .failed:
                // Caller's still `DisciplineHero` already sits underneath in the card; this stays
                // visually quiet (a thin gradient) so a dropped asset isn't a dead black box.
                gradient
            }
        }
        .clipped()
        .accessibilityIdentifier("feed.card.heroClip")
        .task(id: clip.assetId) { await load() }
        .onDisappear { teardown() }
    }

    private var gradient: some View {
        LinearGradient(colors: [SnappetColor.kilter.opacity(0.5), .black],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: Lifecycle

    /// Resolve the PHAsset → muted, looped `AVPlayer` over the ranked segment; fall back to a still
    /// poster frame (then the gradient) when the asset can't be read. Off the main hop via the
    /// PHImageManager continuations; the boxed (non-Sendable) item crosses serially.
    private func load() async {
        teardown()
        state = .loading

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [clip.assetId], options: nil)
        guard let asset = assets.firstObject else { await loadPoster(); return }

        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true        // allow iCloud-stored clips to download
        opts.deliveryMode = .automatic
        // AVPlayerItem isn't Sendable → box it to cross the continuation boundary (mirrors MediaBrowserView).
        let boxed: Box<AVPlayerItem?> = await withCheckedContinuation { cont in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { item, _ in
                cont.resume(returning: Box(item))
            }
        }
        // Could have left the slot (different active card) while the request was in flight.
        guard !Task.isCancelled, let item = boxed.value else {
            if boxed.value == nil { await loadPoster() }
            return
        }

        item.audioMix = nil                       // belt-and-braces: no audio track contribution
        let queue = AVQueuePlayer()
        queue.isMuted = true                      // no audio leak — ever
        queue.preventsDisplaySleepDuringVideoPlayback = false

        // Loop ONLY the ranked segment: [offsetSec, offsetSec + durationSec]. A zero/short duration
        // (e.g. a photo still slipped through) loops the whole item rather than a 0-length range.
        let timescale: CMTimeScale = 600
        let range: CMTimeRange?
        if clip.durationSec > 0.05 {
            range = CMTimeRange(start: CMTime(seconds: clip.offsetSec, preferredTimescale: timescale),
                                duration: CMTime(seconds: clip.durationSec, preferredTimescale: timescale))
        } else {
            range = nil
        }
        if let range {
            looper = AVPlayerLooper(player: queue, templateItem: item, timeRange: range)
        } else {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        }
        player = queue
        state = .playing
        queue.play()
    }

    /// Still poster frame for the segment start (graceful fallback). Reuses the proven
    /// `PHImageManager.requestImage` pattern from ReelView's `HighlightThumbnail`.
    private func loadPoster() async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [clip.assetId], options: nil)
        guard let asset = assets.firstObject else { state = .failed; return }
        let target = CGSize(width: 1080, height: 1080)
        let imgOpts = PHImageRequestOptions()
        imgOpts.deliveryMode = .highQualityFormat
        imgOpts.isNetworkAccessAllowed = true
        let loaded: UIImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: target,
                                                  contentMode: .aspectFill, options: imgOpts) { img, _ in
                cont.resume(returning: img)
            }
        }
        guard !Task.isCancelled else { return }
        if let loaded { poster = loaded; state = .poster } else { state = .failed }
    }

    /// Pause + release the player so at most one `AVPlayer` is ever alive (single-active rule).
    private func teardown() {
        player?.pause()
        player = nil
        looper = nil
    }
}

// MARK: - Chromeless AVPlayer surface (self-contained; R6 consolidates with MediaBrowserView)

/// A bare `AVPlayerLayer` (no AVKit transport chrome) so the clip plays full-bleed in the hero
/// slot, story-style. Muted + looped by the owner; this view only renders.
private struct ClipHeroLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> HeroPlayerContainerView {
        let view = HeroPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill   // fill the hero slot, no letterbox
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: HeroPlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class HeroPlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Wraps a non-Sendable value so it can cross an async continuation boundary.
/// Safe here: each boxed value is produced and consumed exactly once, serially.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
