import SwiftUI
import AVKit
import Photos
import UIKit

// MARK: - Recap Feed — session media browser (F3b)
//
// Instagram-style browser of ALL a session's clips, grouped by exercise / session / All, each with a
// per-clip HR overlay (from FeedMedia.clipHR) + a name tag. Tiles show the real PHAsset poster frame and
// the full-screen viewer plays the actual clip on device (auto-play + loop). Both degrade gracefully to a
// gradient/placeholder when the asset can't be resolved (deleted, not granted under limited Photos
// access, or the simulator, which has no library) — the structure stays verifiable either way.

struct MediaBrowserView: View {
    let media: [MediaInput]
    let hrSeries: [HRPoint]
    let maxHR: Double
    let nameFor: (String) -> String     // group key (exerciseId / climbUUID) → label

    @Environment(\.dismiss) private var dismiss
    @State private var grouping: FeedMedia.Grouping = .byExercise
    @State private var viewer: MediaInput?

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
                                        tile(item).onTapGesture { viewer = item }
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
            .fullScreenCover(item: $viewer) { item in
                MediaViewer(item: item, hr: clipHR(item), name: tagName(item))
            }
        }
        .accessibilityIdentifier("feed.media")
    }

    private func clipHR(_ m: MediaInput) -> MediaClipHR {
        FeedMedia.clipHR(offsetSec: m.offsetSec, durationSec: m.durationSec, hrSeries: hrSeries, maxHR: maxHR)
    }

    private func tagName(_ m: MediaInput) -> String {
        nameFor(m.exerciseId?.uuidString ?? m.climbUUID ?? "general")
    }

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
/// `HighlightThumbnail` loader in ReelView.
private struct ClipThumbnail: View {
    let localIdentifier: String
    let kind: String
    let size: CGSize
    @State private var image: UIImage?

    // MainActor-isolated via the View conformance, so the shared cache is concurrency-safe.
    private static let manager = PHCachingImageManager()

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
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return }
        let target = CGSize(width: size.width * 3, height: size.height * 3)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat          // single callback (no degraded pass)
        options.isNetworkAccessAllowed = false             // posters stay local + fast
        let manager = Self.manager
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: options) { img, _ in
                continuation.resume(returning: img)
            }
        }
        if let loaded { image = loaded }
    }
}

// MARK: - Full-screen clip viewer (real on-device playback)

private struct MediaViewer: View {
    let item: MediaInput
    let hr: MediaClipHR
    let name: String
    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable { case loading, ready, failed }

    @State private var state: LoadState = .loading
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?   // retained or looping stops
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            mediaLayer.ignoresSafeArea()

            // Scrim so the title + HR overlay stay legible over bright footage.
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(alignment: .leading) {
                HStack {
                    Label(name, systemImage: item.kind == "video" ? "video.fill" : "photo.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                        .accessibilityIdentifier("feed.media.close")
                }
                Spacer()
                if let peak = hr.peakBpm {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HEART RATE · THIS CLIP").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                        Text("\(peak) BPM").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        if let z = hr.zoneRaw, let zone = HeartRateZone(rawValue: z) {
                            Text(zone.pillLabel).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .padding(22)
        }
        .accessibilityIdentifier("feed.media.viewer")
        .task { await load() }
        .onDisappear { player?.pause(); player = nil; looper = nil }
    }

    @ViewBuilder private var mediaLayer: some View {
        if state == .loading {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == "video", let player {
            ClipPlayerLayer(player: player)
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

    private func load() async {
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
            queue.play()
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

/// Chromeless AVPlayer surface (no AVKit transport controls) so the clip plays full-bleed under the
/// HR overlay, story-style. Tap toggles play/pause via the parent.
private struct ClipPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Wraps a non-Sendable value so it can cross an async continuation boundary.
/// Safe here: each boxed value is produced and consumed exactly once, serially.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
