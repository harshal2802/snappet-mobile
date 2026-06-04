import SwiftUI
import UIKit
import AVFoundation

/// A controls-free video surface backed by `AVPlayerLayer` (`.resizeAspect`) — unlike `VideoPlayer`,
/// it shows no native transport, so the studio drives play/pause/scrub itself and the displayed video
/// rect is a plain aspect-fit (matching `ClipEditGeometry.displayRect`, so the overlay layer aligns).
struct StudioPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
