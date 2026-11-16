import SwiftUI
import AVFoundation

// MARK: - The rally's video with controls (prompt 257, device feedback on the tag sheet)
//
// "Video look so small on this page and there are no controls." The box now takes the picture's own shape (full width,
// capped in height, no side bars), and the picture carries the Watch player's controls: tap to play / pause (a brief
// centre glyph), Replay, speed (1× · 0.5× · 0.25×), Rotate (a quarter turn, kept on the recording) and full screen with
// pinch-zoom and pan. Under it: a scrub bar over the looped stretch (the rally highlighted) and "−3 s" / "+3 s" to see
// what led to it. Pure decisions: `RacketRallyVideoControls.swift`, `RacketVideoTurn` (`RacketVideoOrientation.swift`),
// `RacketPlayerZoom` (`RacketPlayerWatch.swift`).

/// One rally video's playback and controls, shared by the inline view and its full-screen view.
@MainActor
@Observable
final class RacketRallyVideoModel {
    private(set) var playback: RacketPlayback?
    private(set) var loop: RacketRallyLoop?
    /// The viewer wants it playing (it loops); false after Pause.
    private(set) var looping = true
    /// Remembered while the sheet is open (the view keeps this model across rallies).
    private(set) var speed: Float = 1
    private(set) var scrubbing = false
    /// The centre glyph flashed by a tap on the picture (token changes on each flash).
    private(set) var glyph: (symbol: String, token: Int)?

    var playing: Bool { looping && !scrubbing }

    func attach(_ pb: RacketPlayback) { playback = pb; pb.rate = speed }

    /// A new rally (or the first): loop it, padded a second each side (not widened), from its start.
    func show(rally: ClosedRange<Double>?, partStart: Double, partEnd: Double, play: Bool = true) {
        loop = rally.map { RacketRallyLoop(rally: $0, partStart: partStart, partEnd: partEnd) }
        looping = true
        if play { replay() }
    }

    func replay() {
        guard let pb = playback, let l = loop?.window else { return }
        looping = true
        pb.rate = speed
        pb.play(from: l.lowerBound, until: l.upperBound)
    }

    /// The loop watchdog (every quarter second): at the loop's end, or outside it, start again.
    func tick() {
        guard looping, !scrubbing, let pb = playback, let l = loop,
              l.shouldRestart(position: pb.position, playing: pb.playing) else { return }
        replay()
    }

    func togglePlay() {
        let t = RacketRallyVideoTap.toggle(playing: playing)
        glyph = (t.glyph, (glyph?.token ?? 0) + 1)
        t.play ? resume() : pause()
    }

    func clearGlyph(_ token: Int) { if glyph?.token == token { glyph = nil } }

    func pause() {
        looping = false
        playback?.pause()
    }

    /// Play from where it is (or the loop's start when it's at the end or outside it).
    func resume() {
        guard let pb = playback, let l = loop else { return }
        looping = true
        pb.rate = speed
        let w = l.window
        let from = pb.position >= w.upperBound - 0.15 || pb.position < w.lowerBound - 0.05 ? w.lowerBound : pb.position
        pb.play(from: from, until: w.upperBound)
    }

    func cycleSpeed() {
        speed = RacketRallyVideoSpeed.next(speed)
        playback?.rate = speed
    }

    /// "−3 s": loop from earlier, and play from the new start (what led to the rally).
    func widenEarlier() {
        loop?.widenEarlier()
        replay()
    }

    /// "+3 s": loop further on; keeps playing from where it is.
    func widenLater() {
        loop?.widenLater()
        if looping { resume() }
    }

    /// Dragging the scrub bar: paused, the frame follows the finger.
    func scrub(toFraction f: Double, width: Double) {
        guard let pb = playback, let l = loop else { return }
        if !scrubbing { scrubbing = true; pb.pause() }
        pb.scrub(to: l.time(atFraction: f), tolerance: RacketScrub.tolerance(windowSec: l.length, widthPoints: width))
    }

    /// Released: land exactly there and carry on looping from it.
    func endScrub(atFraction f: Double) {
        guard let pb = playback, let l = loop else { scrubbing = false; return }
        let t = l.time(atFraction: f)
        pb.seek(to: t)
        scrubbing = false
        looping = true
        pb.rate = speed
        pb.play(from: t >= l.window.upperBound - 0.15 ? l.window.lowerBound : t, until: l.window.upperBound)
    }

    func step(_ sec: Double) {
        guard let pb = playback, let l = loop else { return }
        let t = min(l.window.upperBound, max(l.window.lowerBound, pb.position + sec))
        if looping { pb.play(from: t, until: l.window.upperBound) } else { pb.seek(to: t) }
    }

    /// Rotate: one more quarter turn; returns the recording's new turn to save.
    func rotate() -> Int {
        let t = RacketVideoTurn.next(playback?.quarterTurns)
        playback?.quarterTurns = t
        return t
    }
}

// MARK: - The box: the picture's own shape, capped

/// A playback's video in a box shaped like the picture (full width; taller than `maxHeight` ⇒ narrower, centred),
/// with `overlay` laid over exactly the box. Before the shape is known: the placeholder 16:9.
struct RacketVideoBox<Overlay: View>: View {
    let playback: RacketPlayback?
    var sport: RacketSport = .tableTennis
    let maxHeight: CGFloat
    var id = "racket.rallyVideo.box"
    @ViewBuilder var overlay: (CGSize) -> Overlay

    @State private var width: CGFloat = 0

    var body: some View {
        let box = RacketVideoTurn.box(aspect: playback?.displayedSize.flatMap { RacketVideoTurn.aspect($0, turns: 0) },
                                      width: width, maxHeight: maxHeight)
        ZStack {
            if let pb = playback {
                RacketVideoSurface(playback: pb, sport: sport, height: box.height, width: box.width)
            } else {
                Color(white: 0.11).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            overlay(box)
        }
        .frame(width: box.width, height: box.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

// MARK: - The rally's video (tag sheet, serve / wall / let, shots)

struct RacketRallyVideo: View {
    let log: RacketRecordingLog?
    let partStart: Double
    let partEnd: Double
    /// The rally (recording time); changes when the sheet moves to another rally.
    let range: ClosedRange<Double>?
    var sport: RacketSport = .tableTennis
    /// The tallest the picture may be (the tag sheet passes `RacketVideoTurn.tagSheetCap`).
    var maxHeight: CGFloat = 280
    /// Rotate: saves the recording's new turn. nil hides Rotate.
    var onTurn: ((Int) -> Void)? = nil

    @State private var model = RacketRallyVideoModel()
    @State private var fullScreen = false

    var body: some View {
        VStack(spacing: 8) {
            RacketVideoBox(playback: model.playback, sport: sport, maxHeight: maxHeight) { box in
                RacketRallyPictureControls(model: model, box: box, idPrefix: "racket.rallyVideo.",
                                           onTurn: onTurn, onExpand: { fullScreen = true })
            }
            if model.loop != nil {
                RacketRallyScrubBar(model: model, idPrefix: "racket.rallyVideo.")
                RacketRallyContextRow(model: model, idPrefix: "racket.rallyVideo.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.rallyVideo")
        .task {
            guard model.playback == nil else { return }
            let pb = RacketPlayback(partStart: partStart, partEnd: partEnd, startAt: range.map { $0.lowerBound - RacketRallyLoop.pad })
            pb.quarterTurns = RacketVideoTurn.normalized(log?.quarterTurns)
            model.attach(pb)
            model.show(rally: range, partStart: partStart, partEnd: partEnd, play: false)
            if let log { await pb.load(RacketVideoMap.segments(start: partStart, end: partEnd, log: log)) }
            model.replay()
        }
        .task(id: "\(range?.lowerBound ?? -1)-\(range?.upperBound ?? -1)") {
            // A new rally: loop it from its start (the speed stays as chosen).
            if model.playback?.loaded == true { model.show(rally: range, partStart: partStart, partEnd: partEnd) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                model.tick()
            }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            RacketRallyVideoFullScreen(model: model, sport: sport, onTurn: onTurn)
        }
        .onDisappear { if !fullScreen { model.playback?.stop() } }
    }
}

// MARK: - Controls on the picture

/// Tap the picture to play / pause (a brief centre glyph); play / pause and Replay bottom left; speed and Rotate bottom
/// right; full screen (or Done) top right. Buttons are 44 pt.
struct RacketRallyPictureControls: View {
    let model: RacketRallyVideoModel
    let box: CGSize
    let idPrefix: String
    var onTurn: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    /// The inline picture takes taps here; full screen has the gesture surface (pinch, pan) instead.
    var pictureTap = true

    var body: some View {
        if let pb = model.playback {
            let fit = RacketPlayerFit.fitted(video: pb.displayedSize ?? box, in: box)
            ZStack {
                // The picture itself: tap toggles play / pause. Over the stand-in only when there's a video.
                if pictureTap, pb.player != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                        .onTapGesture { model.togglePlay() }
                        .accessibilityElement()
                        .accessibilityLabel("Video")
                        .accessibilityValue(model.loop.map { $0.timeLine(pb.position) } ?? "")
                        .accessibilityHint(model.playing ? "Pauses" : "Plays")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.togglePlay() }
                        .accessibilityIdentifier(idPrefix + "picture")
                }
                if let g = model.glyph {
                    Image(systemName: g.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .accessibilityIdentifier(idPrefix + "glyph")
                        .task(id: g.token) {
                            try? await Task.sleep(for: .milliseconds(700))
                            withAnimation(.easeOut(duration: 0.2)) { model.clearGlyph(g.token) }
                        }
                }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let onExpand {
                            circle("arrow.up.left.and.arrow.down.right", label: "Full screen", id: "expand", action: onExpand)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        circle(model.playing ? "pause.fill" : "play.fill", label: model.playing ? "Pause" : "Play", id: "play") {
                            model.playing ? model.pause() : model.resume()
                        }
                        circle("arrow.counterclockwise", label: "Replay", id: "replay") { model.replay() }
                        Spacer(minLength: 0)
                        speedButton
                        if let onTurn {
                            circle("rotate.right", label: "Rotate video", id: "rotate",
                                   value: "\(Int(RacketVideoTurn.degrees(pb.quarterTurns)))°") { onTurn(model.rotate()) }
                        }
                    }
                }
                .padding(4)
            }
            .frame(width: box.width, height: box.height)
        }
    }

    private var speedButton: some View {
        Button { model.cycleSpeed() } label: {
            Text(RacketPlayerText.speed(model.speed)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .monospacedDigit()
                .frame(minWidth: 36, minHeight: 30)
                .padding(.horizontal, 4)
                .background(Color.black.opacity(0.6), in: Capsule())
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed")
        .accessibilityValue(RacketPlayerText.speed(model.speed))
        .accessibilityIdentifier(idPrefix + "speed")
    }

    private func circle(_ symbol: String, label: String, id: String, value: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.6), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(idPrefix + id)
    }
}

// MARK: - Under the picture: the scrub bar and the context buttons

/// The looped stretch as a bar, the rally highlighted, the playhead; drag to scrub (paused, frames follow the finger;
/// release carries on looping).
struct RacketRallyScrubBar: View {
    let model: RacketRallyVideoModel
    let idPrefix: String

    var body: some View {
        if let l = model.loop, let pb = model.playback {
            GeometryReader { g in
                let w = max(1, g.size.width)
                let r = l.rallyFractions
                let x = l.fraction(of: pb.position) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 6)
                    Capsule().fill(SnappetColor.brand.opacity(0.55))
                        .frame(width: max(4, (r.to - r.from) * w), height: 6)
                        .offset(x: r.from * w)
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: max(0, x), height: 6)
                        .opacity(0.35)
                    Circle().fill(Color.white).frame(width: model.scrubbing ? 20 : 14, height: model.scrubbing ? 20 : 14)
                        .shadow(radius: 2)
                        .offset(x: x - (model.scrubbing ? 10 : 7))
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in model.scrub(toFraction: Double(v.location.x / w), width: Double(w)) }
                    .onEnded { v in model.endScrub(atFraction: Double(v.location.x / w)) })
            }
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel("Rally video position")
            .accessibilityValue(l.timeLine(pb.position))
            .accessibilityAdjustableAction { dir in model.step(dir == .increment ? 1 : -1) }
            .accessibilityIdentifier(idPrefix + "scrub")
        }
    }
}

/// "−3 s" · the time in the loop and its length · "+3 s".
struct RacketRallyContextRow: View {
    let model: RacketRallyVideoModel
    let idPrefix: String
    var tint: Color = SnappetColor.textSecondary

    var body: some View {
        if let l = model.loop, let pb = model.playback {
            HStack(spacing: 8) {
                button(RacketPlayerText.skip(-RacketRallyLoop.step), label: "Show 3 seconds earlier", id: "earlier",
                       enabled: l.canWidenEarlier) { model.widenEarlier() }
                Spacer(minLength: 4)
                Text(l.timeLine(pb.position)).font(SnappetType.detail.monospacedDigit()).foregroundStyle(tint)
                    .accessibilityIdentifier(idPrefix + "time")
                Spacer(minLength: 4)
                button(RacketPlayerText.skip(RacketRallyLoop.step), label: "Show 3 seconds later", id: "later",
                       enabled: l.canWidenLater) { model.widenLater() }
            }
        }
    }

    private func button(_ text: String, label: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(minWidth: 64, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SnappetColor.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(idPrefix + id)
    }
}

// MARK: - Full screen

/// The same clip and controls on the whole screen, with the Watch player's pinch-zoom and pan (`RacketPlayerZoom`),
/// and Done.
struct RacketRallyVideoFullScreen: View {
    let model: RacketRallyVideoModel
    var sport: RacketSport = .tableTennis
    var onTurn: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: Double = 1
    @State private var zoomAtStart: Double = 1
    @State private var pan: CGSize = .zero
    @State private var panAtStart: CGSize = .zero

    private let prefix = "racket.rallyVideo.full."

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Done") { dismiss() }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier(prefix + "done")
                Spacer()
                if RacketPlayerZoom.isZoomed(zoom) {
                    Button(RacketPlayerText.zoom(zoom)) { resetZoom() }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Reset zoom")
                        .accessibilityIdentifier(prefix + "zoom")
                }
            }
            .padding(.horizontal, 12)
            GeometryReader { g in
                stage(g.size)
            }
            RacketRallyScrubBar(model: model, idPrefix: prefix).padding(.horizontal, 16)
            RacketRallyContextRow(model: model, idPrefix: prefix).padding(.horizontal, 16).padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.rallyVideo.full")
    }

    @ViewBuilder private func stage(_ size: CGSize) -> some View {
        if let pb = model.playback {
            let fit = RacketPlayerFit.fitted(video: pb.displayedSize ?? size, in: size)
            ZStack {
                // Zoomed, the video's layer reaches past the stage: it must not take the top bar's or the scrub bar's taps.
                RacketVideoSurface(playback: pb, sport: sport, height: size.height)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .allowsHitTesting(false)
                RacketPlayerGestureSurface(
                    zoomed: RacketPlayerZoom.isZoomed(zoom),
                    onTap: { _, _ in model.togglePlay() },
                    onHold: { _ in },
                    onPinch: { scale, phase in
                        switch phase {
                        case .began: zoomAtStart = zoom
                        case .changed:
                            zoom = RacketPlayerZoom.clamp(zoomAtStart * scale)
                            pan = RacketPlayerZoom.clampOffset(pan, scale: zoom, video: fit.size, view: size)
                        case .ended: if !RacketPlayerZoom.isZoomed(zoom) { resetZoom() }
                        }
                    },
                    onPan: { translation, phase in
                        switch phase {
                        case .began: panAtStart = pan
                        case .changed:
                            pan = RacketPlayerZoom.clampOffset(CGSize(width: panAtStart.width + translation.width,
                                                                      height: panAtStart.height + translation.height),
                                                               scale: zoom, video: fit.size, view: size)
                        case .ended: break
                        }
                    })
                .accessibilityElement()
                .accessibilityLabel("Video")
                .accessibilityValue(RacketPlayerText.zoom(zoom))
                .accessibilityHint(model.playing ? "Pauses" : "Plays")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.togglePlay() }
                .accessibilityAction(named: "Reset zoom") { resetZoom() }
                .accessibilityIdentifier(prefix + "surface")
                RacketRallyPictureControls(model: model, box: size, idPrefix: prefix, onTurn: turnHandler,
                                           onExpand: nil, pictureTap: false)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    /// Rotate in full screen: the zoom starts again on the turned picture.
    private var turnHandler: ((Int) -> Void)? {
        guard let onTurn else { return nil }
        return { t in
            resetZoom()
            onTurn(t)
        }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero }
    }
}
