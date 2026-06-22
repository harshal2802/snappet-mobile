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

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = backgroundColor
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        if uiView.backgroundColor != backgroundColor { uiView.backgroundColor = backgroundColor }
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
