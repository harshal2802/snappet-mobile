import SwiftUI
import AVFoundation

// MARK: - Clips fullscreen transport (prompt 94)
//
// Play/pause + a scrubbable timeline + mute for the Clips fullscreen player. The active fullscreen page's
// `ClipMediaSurface` plays a **non-looping** `AVPlayer` (clean 0…duration scrubbing) and attaches it here;
// this controller observes the player's time and issues seek / play-pause / mute, so `MediaTransportBar`
// stays a thin view. The HR overlay follows for free: the surface's playhead ticker reads the same
// `player.currentTime()` (which a seek moves), so the scorebug dot tracks the scrub.

@MainActor
@Observable
final class ClipPlaybackController {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 1
    private(set) var isPlaying = false
    private(set) var isMuted = false
    /// True while the user drags the scrubber — suppresses the time-observer write-back so the thumb
    /// doesn't fight the drag.
    var isScrubbing = false

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    /// The played range's start within the source asset (a Studio-trimmed clip, prompt 116): the
    /// scrubber/timecode work in 0…`duration` of the KEPT range; seeks and the time observer translate
    /// through this offset. 0 for an untrimmed clip.
    private var startOffset: Double = 0

    var fraction: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }

    /// Attach the page's player + the played span (the kept range's length for a trimmed clip, else the
    /// asset duration) + the kept range's start within the asset.
    func attach(_ player: AVPlayer, duration: Double, startOffset: Double = 0) {
        detach()
        self.player = player
        self.duration = max(0.1, duration)
        self.startOffset = max(0, startOffset)
        self.isMuted = player.isMuted
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            // The observer fires on the main queue, so we're already on the MainActor — assert it so the
            // @Sendable closure can touch this actor-isolated state synchronously (Swift 6).
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let s = t.seconds
                if s.isFinite { self.currentTime = min(self.duration, max(0, s - self.startOffset)) }
                self.isPlaying = (self.player?.rate ?? 0) != 0
            }
        }
    }

    func detach() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
    }

    func togglePlay() {
        guard let player else { return }
        if player.rate == 0 {
            if currentTime >= duration - 0.05 { seek(toFraction: 0) }   // at the end → replay from the start
            player.play()
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        isMuted = player.isMuted
    }

    /// Seek to a 0…1 fraction of the PLAYED range (kept range for a trimmed clip). `precise` uses zero
    /// tolerance (drag release / tap); a tolerant seek keeps live dragging smooth.
    func seek(toFraction f: Double, precise: Bool = true) {
        currentTime = min(duration, max(0, f * duration))
        let t = CMTime(seconds: startOffset + currentTime, preferredTimescale: 600)
        let tol: CMTime = precise ? .zero : CMTime(seconds: 0.4, preferredTimescale: 600)
        player?.seek(to: t, toleranceBefore: tol, toleranceAfter: tol)
    }
}

/// The Clips fullscreen transport bar: play/pause · `m:ss` · scrubber · `m:ss` · mute.
struct MediaTransportBar: View {
    @Bindable var controller: ClipPlaybackController

    var body: some View {
        HStack(spacing: 12) {
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(.white).frame(width: 26)
            }
            .accessibilityIdentifier("clips.fullscreen.playpause")
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Text(timecode(controller.currentTime))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white)

            Slider(value: Binding(get: { controller.fraction },
                                  set: { controller.seek(toFraction: $0, precise: false) }),
                   in: 0...1) { editing in
                controller.isScrubbing = editing
                if !editing { controller.seek(toFraction: controller.fraction, precise: true) }
            }
            .tint(.white)
            .accessibilityIdentifier("clips.fullscreen.scrubber")

            Text(timecode(controller.duration))
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))

            Button { controller.toggleMute() } label: {
                Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 24)
            }
            .accessibilityIdentifier("clips.fullscreen.mute")
            .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.black.opacity(0.4), in: Capsule())
        .padding(.horizontal, 16)
    }

    private func timecode(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
