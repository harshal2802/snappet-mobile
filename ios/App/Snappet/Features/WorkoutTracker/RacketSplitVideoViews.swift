import SwiftUI

// MARK: - The split sheet's video (prompt 258)
//
// TtSplitEdit gets the prompt-257 rally video's box and controls: the picture's own shape (capped), tap to play /
// pause with the centre glyph, Play / Pause, speed (1× · 0.5× · 0.25×), full screen with pinch-zoom, and the
// recording's turn honoured. The range strip under it stays the scrubber. Play follows `RacketScrub.playStart`: from
// the playhead inside the part, else from the part's start, to the part's end.

struct RacketSplitVideo: View {
    let playback: RacketPlayback
    var sport: RacketSport = .tableTennis
    /// The part being fixed (its edges move while editing).
    let start: Double
    let end: Double
    var maxHeight: CGFloat = 260

    @State private var glyph: (symbol: String, token: Int)?
    @State private var fullScreen = false

    var body: some View {
        RacketVideoBox(playback: playback, sport: sport, maxHeight: maxHeight, id: "racket.split.edit.video") { box in
            controls(box: box, idPrefix: "racket.split.edit.", expand: true)
        }
        .fullScreenCover(isPresented: $fullScreen) {
            RacketSplitVideoFullScreen(playback: playback, sport: sport, start: start, end: end)
        }
    }

    /// Play the part from where the rule says, to its end; or pause.
    static func toggle(_ pb: RacketPlayback, start: Double, end: Double) {
        if pb.playing { pb.pause(); return }
        pb.play(from: RacketScrub.playStart(playhead: pb.position, start: start, end: end), until: end)
    }

    @ViewBuilder func controls(box: CGSize, idPrefix: String, expand: Bool, pictureTap: Bool = true) -> some View {
        let fit = RacketPlayerFit.fitted(video: playback.displayedSize ?? box, in: box)
        ZStack {
            if pictureTap {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: fit.width, height: fit.height)
                .position(x: fit.midX, y: fit.midY)
                .onTapGesture { tap() }
                .accessibilityElement()
                .accessibilityLabel("Video")
                .accessibilityValue(RacketVideoTime.clock(playback.position))
                .accessibilityHint(playback.playing ? "Pauses" : "Plays this part")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { tap() }
                .accessibilityIdentifier(idPrefix + "picture")
            }
            if let g = glyph {
                Image(systemName: g.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(idPrefix + "glyph")
                    .task(id: g.token) {
                        try? await Task.sleep(for: .milliseconds(700))
                        withAnimation(.easeOut(duration: 0.2)) { if glyph?.token == g.token { glyph = nil } }
                    }
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if expand {
                        circle("arrow.up.left.and.arrow.down.right", label: "Full screen", id: idPrefix + "expand") { fullScreen = true }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    circle(playback.playing ? "pause.fill" : "play.fill", label: playback.playing ? "Pause" : "Play",
                           id: idPrefix + "play") { Self.toggle(playback, start: start, end: end) }
                    Spacer(minLength: 0)
                    Button { playback.rate = RacketRallyVideoSpeed.next(playback.rate) } label: {
                        Text(RacketPlayerText.speed(playback.rate)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white).monospacedDigit()
                            .frame(minWidth: 36, minHeight: 30).padding(.horizontal, 4)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Speed")
                    .accessibilityValue(RacketPlayerText.speed(playback.rate))
                    .accessibilityIdentifier(idPrefix + "speed")
                }
            }
            .padding(4)
        }
        .frame(width: box.width, height: box.height)
    }

    private func tap() {
        let t = RacketRallyVideoTap.toggle(playing: playback.playing)
        glyph = (t.glyph, (glyph?.token ?? 0) + 1)
        Self.toggle(playback, start: start, end: end)
    }

    private func circle(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.6), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The part on the whole screen: the same controls, pinch-zoom and pan (the Watch player's clamp), the playhead, Done.
struct RacketSplitVideoFullScreen: View {
    let playback: RacketPlayback
    var sport: RacketSport = .tableTennis
    let start: Double
    let end: Double

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: Double = 1
    @State private var zoomAtStart: Double = 1
    @State private var pan: CGSize = .zero
    @State private var panAtStart: CGSize = .zero

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Done") { dismiss() }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("racket.split.edit.full.done")
                Spacer()
                Text("\(RacketVideoTime.clock(playback.position)) · \(RacketVideoTime.range(start, end))")
                    .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.split.edit.full.time")
            }
            .padding(.horizontal, 12)
            GeometryReader { g in
                let size = g.size
                let fit = RacketPlayerFit.fitted(video: playback.displayedSize ?? size, in: size)
                ZStack {
                    RacketVideoSurface(playback: playback, sport: sport, height: size.height)
                        .scaleEffect(zoom).offset(pan).allowsHitTesting(false)
                    RacketPlayerGestureSurface(
                        zoomed: RacketPlayerZoom.isZoomed(zoom),
                        onTap: { _, _ in RacketSplitVideo.toggle(playback, start: start, end: end) },
                        onHold: { _ in },
                        onPinch: { scale, phase in
                            switch phase {
                            case .began: zoomAtStart = zoom
                            case .changed:
                                zoom = RacketPlayerZoom.clamp(zoomAtStart * scale)
                                pan = RacketPlayerZoom.clampOffset(pan, scale: zoom, video: fit.size, view: size)
                            case .ended: if !RacketPlayerZoom.isZoomed(zoom) { zoom = 1; pan = .zero }
                            }
                        },
                        onPan: { t, phase in
                            switch phase {
                            case .began: panAtStart = pan
                            case .changed:
                                pan = RacketPlayerZoom.clampOffset(CGSize(width: panAtStart.width + t.width, height: panAtStart.height + t.height),
                                                                   scale: zoom, video: fit.size, view: size)
                            case .ended: break
                            }
                        })
                    .accessibilityElement()
                    .accessibilityLabel("Video")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { RacketSplitVideo.toggle(playback, start: start, end: end) }
                    .accessibilityIdentifier("racket.split.edit.full.surface")
                    RacketSplitVideo(playback: playback, sport: sport, start: start, end: end)
                        .controls(box: size, idPrefix: "racket.split.edit.full.", expand: false, pictureTap: false)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
        }
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
