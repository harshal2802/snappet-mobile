import SwiftUI
import UIKit
import AVFoundation

/// A controls-free video surface backed by `AVPlayerLayer` (`.resizeAspect`) — unlike `VideoPlayer`,
/// it shows no native transport, so the studio drives play/pause/scrub itself and the displayed video
/// rect is a plain aspect-fit (matching `ClipEditGeometry.displayRect`, so the overlay layer aligns).
///
/// Shared by the studio editor (transparent backing, so the canvas shows through the aspect-fit
/// letterbox) and the Recap Feed's full-bleed clip viewer (black backing, story-style). The
/// single-active-player discipline lives in the *caller* (only the centered page assigns/plays a
/// player); this view is a passive surface and imposes no policy of its own.
struct StudioPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// The backing colour shown in the aspect-fit letterbox. `.clear` (default) lets the studio canvas
    /// show through; the feed viewer passes `.black` for a full-bleed story look.
    var backgroundColor: UIColor = .clear
    /// How the video fills its layer. `.resizeAspect` (default) letterboxes — required by the studio +
    /// fullscreen viewer so the overlay aligns. The Clips feed tile passes `.resizeAspectFill` so a clip
    /// fills its (aspect-matched) tile with no black bars (prompt 92, device fix).
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// Fires (on the main actor) when the layer's `isReadyForDisplay` flips — the caller keeps a poster over
    /// the layer until the FIRST FRAME is decoded, then crossfades the video in (Apple's recommended handoff,
    /// WWDC 2019 §503). A just-mounted/just-repointed `AVPlayerLayer` presents NO content until this is true,
    /// so revealing it early is the ~1-frame carousel-swipe flicker.
    var onReadyForDisplayChange: (@MainActor (Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.backgroundColor = backgroundColor
        context.coordinator.bind(view.playerLayer, onReadyForDisplayChange)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.bind(uiView.playerLayer, onReadyForDisplayChange)   // re-observe the re-pointed layer
        }
        if uiView.backgroundColor != backgroundColor { uiView.backgroundColor = backgroundColor }
        if uiView.playerLayer.videoGravity != videoGravity { uiView.playerLayer.videoGravity = videoGravity }
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        private var obs: NSKeyValueObservation?
        func bind(_ layer: AVPlayerLayer, _ cb: (@MainActor (Bool) -> Void)?) {
            obs?.invalidate()
            guard let cb else { obs = nil; return }
            obs = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in cb(ready) }
            }
        }
        deinit { obs?.invalidate() }
    }
}
