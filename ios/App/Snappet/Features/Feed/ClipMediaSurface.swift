import SwiftUI
import AVKit
import Photos
import UIKit
import Combine

// MARK: - Clips feed — the ONE inline media surface (player engine + live HR fraction) — prompt 85
//
// The single media engine shared by the fullscreen viewer (`MediaPage`) and the inline carousel poster:
// it owns one `AVQueuePlayer` + `AVPlayerLooper` for a video (or a still `UIImage` for a photo), loads it
// async from the clip's `PHAsset`, plays ONLY while `isActive`, tears down on disappear, and drives a live
// playhead `fraction` (via the `ClipHROverlay` SSOT) so the caller's HR tile tracks playback. ONE
// `AVPlayerLayer` lifecycle in ONE place — the discipline that keeps inline playback off the R12 "black
// box" path (which came from assigning players to recycled scrolling rows, not from the layer itself).
//
// Renders the media layer + tap-to-pause only; the caller frames it and lays its own chrome / HR tile over.

struct ClipMediaSurface: View {
    let clip: MediaInput
    /// Single-active gate: only the active surface plays; others pause (kept warm) until torn down.
    let isActive: Bool
    /// The clip's HR overlay (supplies the fraction's `maxT` axis); `nil` ⇒ no HR ⇒ fraction stays at rest.
    let payload: ClipHROverlay.Payload?
    /// Live playhead the caller's `HRTileView` reads; this surface WRITES it from the player while playing.
    @Binding var fraction: Double
    /// Letterbox backing colour shown around the aspect-fit video.
    var background: UIColor = .black

    private enum LoadState: Equatable { case loading, ready, failed }

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?   // retained or looping stops
    @State private var image: UIImage?
    @State private var state: LoadState = .loading
    @State private var ticker = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        content
            .task(id: clip.id) { await load() }
            // Single-active: play while centered/active; on de-activate, pause and reset the playhead to the
            // at-end reading so a glimpsed off-active overlay isn't frozen mid-sweep.
            .onChange(of: isActive) { _, active in
                if active { player?.play() } else { player?.pause(); fraction = ClipHROverlay.atEndFraction }
            }
            // Start playback when the item becomes ready — read here (not at the end of the async `load`) so
            // the play decision uses the LIVE `isActive`: a page can de-center mid-load, and the captured
            // value would otherwise auto-play an off-center page.
            .onChange(of: state) { _, ready in if ready == .ready, isActive { player?.play() } }
            // Full teardown only when the surface leaves the view tree (pause + nil player + drop looper).
            .onDisappear { teardown() }
            // Live HR: while THIS active surface's video plays, sweep the playhead via the shared mapping.
            // Inactive / paused / photo / no-HR take the guarded early return (near-zero cost).
            .onReceive(ticker) { _ in
                guard isActive, clip.kind == "video", let player, player.rate != 0, let payload else { return }
                let t = player.currentTime().seconds
                guard t.isFinite else { return }   // item not ready yet → keep the last fraction (no 0-flash)
                fraction = ClipHROverlay.fraction(videoTime: t, clip: clip, payload: payload)
            }
    }

    @ViewBuilder private var content: some View {
        if state == .loading {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if clip.kind == "video", let player {
            StudioPlayerLayerView(player: player, backgroundColor: background)
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
            Image(systemName: clip.kind == "video" ? "play.slash" : "photo")
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
        fraction = ClipHROverlay.atEndFraction   // the at-end reading until the video actually plays
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [clip.localIdentifier], options: nil)
        guard let asset = assets.firstObject else { state = .failed; return }

        if clip.kind == "video" {
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true            // allow iCloud-stored clips to download
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
            state = .ready   // `.onChange(of: state)` starts playback iff still active (live isActive)
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

    /// Wraps a non-Sendable value so it can cross an async continuation boundary (produced + consumed once).
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
