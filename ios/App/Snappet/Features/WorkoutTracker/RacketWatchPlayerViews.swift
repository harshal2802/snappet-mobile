import SwiftUI
import AVFoundation
import UIKit

// MARK: - Racket player, Watch mode (prompt 253, issue #448 part 1 "Watch")
//
// Boards: Main, PlayerChrome, PlayerPaused, PlayerScrub, PlayerSkip, PlayerHold, PlayerSpeed, PlayerModes, PlayerZoom,
// PlayerNoRallies, PlayerOpening, PlayerMissing, PlayerEnd, PlayerLetterbox, PlayerLandscape, PlayerLandscapeChrome.
// A thin renderer over the pure `RacketPlayerWatch.swift`; `RacketPlayback` plays the part from the Photos original.
// Edit and the new Share sheet are the next job (prompt 254): Edit opens today's rally / tag / score surfaces from a
// menu, Share opens today's "Save or share".

struct RacketWatchPlayerScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let ralliesOnly: Bool
    /// The next game / block (PlayerEnd's "Game 2"); nil on the last.
    var nextPart: RacketPartRef? = nil
    var onNextPart: ((RacketPartRef) -> Void)? = nil
    /// PlayerNoRallies "Find rallies" (the sport's model, today the placeholder); nil disables it.
    var onFindRallies: (() -> Void)? = nil
    /// PlayerNoRallies "Mark by hand": the part's timeline.
    var onMarkByHand: (() -> Void)? = nil
    /// The analysis view and other apps' suggestions, reachable from Edit's rally list (prompt 254).
    var onAnalysis: (() -> Void)? = nil
    var compare: (label: String, action: () -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var playback: RacketPlayback?
    @State private var configured = false
    @State private var chrome = true
    @State private var touches = 0
    @State private var taps = RacketPlayerTaps()
    @State private var ripple: Ripple?
    @State private var hold = RacketPlayerHold()
    @State private var zoom: Double = 1
    @State private var zoomAtStart: Double = 1
    @State private var pan: CGSize = .zero
    @State private var panAtStart: CGSize = .zero
    @State private var speedMenu = false
    /// Edit mode (prompt 254) over the player, on the same playback.
    @State private var editing = false
    @State private var onlyRallies = false
    @State private var exporting = false
    @State private var dragging = false
    @State private var dragFrom: Double = 0
    @State private var dragWasPlaying = false
    @State private var lastDrag: (t: Double, at: Date)?
    @State private var thumbnails: [UIImage?] = []
    /// The frame count the strip finished loading (a cancelled load, e.g. the controls hiding, resumes next time).
    @State private var thumbsDone: Int = 0

    private struct Ripple: Equatable {
        var side: RacketPlayerTaps.Side
        var total: Double
        var token: Int
    }

    // MARK: Data

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var rallies: RacketPlayerRallies {
        RacketPlayerRallies(RacketRallyMarking.inRange(ex?.racketRecordingLog?.allRallies ?? [], ref.startSec, ref.endSec))
    }
    private var sides: (us: String, them: String) {
        RacketWatchCopy.sides(opponent: ex?.opponent, doubles: ex?.isDoubles ?? false)
    }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var title: String { RacketPlayerText.title(ref.title) }
    private var duration: Double { max(0, ref.endSec - ref.startSec) }
    private var unitScore: RacketUnitScore? {
        guard let i = ref.setIndex, let sets = ex?.sets, i < sets.count else { return nil }
        return sets[i].racketScore
    }
    private var missing: Bool {
        if case .missing = playback?.loadState { return true }
        return false
    }
    private var downloading: Double? {
        if case .downloading(let f) = playback?.loadState { return f }
        return nil
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            ZStack {
                Color.black.ignoresSafeArea()
                if let pb = playback {
                    if missing {
                        missingCard
                        VStack { topBar(pb, landscape: landscape); Spacer() }
                    } else {
                        stage(pb, full: full, insets: insets, landscape: landscape)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $exporting) {
            if let pb = playback {
                RacketShareSheet(store: store, ref: ref, position: pb.position, rate: pb.rate, look: pb.look)
            }
        }
        .fullScreenCover(isPresented: $editing) {
            if let pb = playback {
                RacketEditScreen(store: store, ref: ref, playback: pb, onAnalysis: onAnalysis, compare: compare) {
                    editing = false
                    withAnimation { chrome = true }
                }
            }
        }
        .task(id: hideKey) {
            try? await Task.sleep(for: .seconds(RacketPlayerChrome.hideAfter))
            guard !Task.isCancelled, let pb = playback else { return }
            if RacketPlayerChrome.shouldHide(visible: chrome, playing: pb.playing, idleSec: RacketPlayerChrome.hideAfter,
                                             dragging: dragging, menuOpen: speedMenu || editing) {
                withAnimation(.easeInOut(duration: 0.25)) { chrome = false }
            }
        }
        .task(id: ripple?.token) {
            guard ripple != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { ripple = nil }
        }
        .onChange(of: playback?.ended ?? false) { _, ended in
            if ended { withAnimation { chrome = true } }
        }
        .onChange(of: onlyRallies) { _, on in
            guard let pb = playback else { return }
            pb.ralliesOnly = on ? rallies.rallies : nil
            if on, rallies.index(at: pb.position) == nil, let next = rallies.nextStart(from: pb.position) { pb.seek(to: next) }
        }
        .task { await configure() }
        .onDisappear { playback?.stop() }
    }

    private var hideKey: String {
        "\(chrome)-\(playback?.playing ?? false)-\(touches)-\(dragging)-\(speedMenu)-\(editing)"
    }

    private func configure() async {
        guard !configured else { return }
        configured = true
        #if DEBUG
        // UI tests only: the headless simulator doesn't turn the app when the test turns the device, so the landscape
        // board walk asks the scene to turn instead.
        if UserDefaults.standard.bool(forKey: "uiTestRacketLandscape"),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        #endif
        let pb = RacketPlayback(partStart: ref.startSec, partEnd: ref.endSec)
        // The look chosen in Edit (prompt 254): this video's, else the match's, else Always.
        pb.look = RacketLookStore.resolve(partStart: ref.startSec, log: ex?.racketRecordingLog,
                                          always: UserDefaults.standard.string(forKey: RacketLookStore.alwaysKey)
                                              .flatMap(RacketLook.init(rawValue:))).look
        playback = pb
        onlyRallies = ralliesOnly && !rallies.isEmpty
        pb.ralliesOnly = onlyRallies ? rallies.rallies : nil
        if onlyRallies, let first = rallies.rallies.first { pb.seek(to: first.startSec) }
        guard let log = ex?.racketRecordingLog else { return }
        let segments = RacketVideoMap.segments(start: ref.startSec, end: ref.endSec, log: log)
        if UserDefaults.standard.string(forKey: String(RacketVideoSeed.playerArgument.dropFirst())) == "opening" {
            await pb.holdOpening(segments, fraction: 0.42)
            return
        }
        let before = touches
        await pb.load(segments)
        if onlyRallies, let first = rallies.rallies.first { pb.seek(to: first.startSec) }
        // Opened from Play: it plays (Photos), and the controls hide after a moment; unless the viewer already
        // paused or moved it while the video was opening.
        if !missing, touches == before { pb.play() }
    }

    // MARK: Stage

    @ViewBuilder private func stage(_ pb: RacketPlayback, full: CGSize, insets: EdgeInsets, landscape: Bool) -> some View {
        let videoSize = pb.videoSize ?? pb.poster?.size
        let fit = RacketPlayerFit.fitted(video: videoSize ?? full, in: full)
        let sideways = RacketPlayerFit.showsTurnHint(video: videoSize, view: full)
        ZStack {
            video(pb, full: full)
                .scaleEffect(zoom)
                .offset(pan)
                .ignoresSafeArea()
            surface(pb, full: full, fit: fit)
                .ignoresSafeArea()
            if !dragging { hiddenChromeOverlays(pb, full: full, insets: insets, fit: fit, sideways: sideways, landscape: landscape) }
            if let r = ripple { rippleView(r).ignoresSafeArea().allowsHitTesting(false) }
            if dragging { scrubReadout(pb) }
            if let f = downloading {
                VStack {
                    pill(RacketPlayerText.downloading(f)).accessibilityIdentifier("racket.player.downloading")
                    Spacer()
                }
                .padding(.top, chrome ? (landscape ? 52 : 64) : 12)
            }
            if chrome || dragging {
                chromeLayer(pb, landscape: landscape)
            }
        }
    }

    /// The video: the player's layer, else the poster while it opens, else the stand-in / a message.
    @ViewBuilder private func video(_ pb: RacketPlayback, full: CGSize) -> some View {
        if let player = pb.player {
            RacketPlayerLayerView(player: player, target: pb.position - pb.partStart)
                .overlay(alignment: .top) {
                    if let line = pb.loadState.line {
                        pill(line).padding(.top, 60).accessibilityIdentifier("racket.player.partial")
                    }
                }
        } else if let poster = pb.poster {
            Image(uiImage: poster).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            ZStack {
                Color(white: 0.11)
                VStack(spacing: 8) {
                    Image(systemName: pb.loadState.isCloud ? "icloud.and.arrow.down" : sport.symbol)
                        .font(.system(size: 30)).foregroundStyle(SnappetColor.textTertiary)
                    Text(pb.loadState.line ?? (pb.loaded ? "No video saved for this recording" : "Loading video…"))
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("racket.player.standIn")
                    if pb.loadState.canRetry {
                        Button("Try again") { Task { await pb.retry() } }
                            .font(.system(size: 15, weight: .semibold))
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("racket.player.retry")
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    /// The gesture surface over the video: tap / double-tap / hold / pinch / pan, with VoiceOver alternatives.
    private func surface(_ pb: RacketPlayback, full: CGSize, fit: CGRect) -> some View {
        RacketPlayerGestureSurface(
            zoomed: RacketPlayerZoom.isZoomed(zoom),
            onTap: { x, width in handleTap(pb, x: x, width: width) },
            onHold: { began in began ? beginHold(pb) : endHold(pb) },
            onPinch: { scale, phase in
                switch phase {
                case .began: zoomAtStart = zoom
                case .changed: zoom = RacketPlayerZoom.clamp(zoomAtStart * scale)
                    pan = RacketPlayerZoom.clampOffset(pan, scale: zoom, video: fit.size, view: full)
                case .ended:
                    if !RacketPlayerZoom.isZoomed(zoom) { resetZoom() }
                }
                touched()
            },
            onPan: { translation, phase in
                switch phase {
                case .began: panAtStart = pan
                case .changed:
                    pan = RacketPlayerZoom.clampOffset(CGSize(width: panAtStart.width + translation.width,
                                                              height: panAtStart.height + translation.height),
                                                       scale: zoom, video: fit.size, view: full)
                case .ended: break
                }
                touched()
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Video")
        .accessibilityValue(RacketPlayerText.timeLine(pb.position - ref.startSec, of: duration))
        .accessibilityHint("Shows or hides the controls")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleChrome() }
        .accessibilityAction(named: "Skip back 10 seconds") { skip(pb, RacketPlayerTaps.accessibilitySkip(.back)) }
        .accessibilityAction(named: "Skip forward 10 seconds") { skip(pb, RacketPlayerTaps.accessibilitySkip(.forward)) }
        .accessibilityAction(named: "Reset zoom") { resetZoom() }
        .accessibilityIdentifier("racket.player.surface")
    }

    // MARK: Without the controls (Main · PlayerSkip · PlayerHold · PlayerModes · PlayerZoom · PlayerLetterbox · PlayerLandscape)

    /// The pills sit on the video's own top corners (inside the safe area): on a letterboxed or pillarboxed video they
    /// stay on the picture, as the boards draw them.
    @ViewBuilder private func hiddenChromeOverlays(_ pb: RacketPlayback, full: CGSize, insets: EdgeInsets, fit: CGRect,
                                                   sideways: Bool, landscape: Bool) -> some View {
        let top = max(insets.top + 10, fit.minY + 10)
        let leading = max(insets.leading + 12, fit.minX + 12)
        let trailing = max(insets.trailing + 12, full.width - fit.maxX + 12)
        let zoomed = RacketPlayerZoom.isZoomed(zoom)
        let t = pb.position
        ZStack {
            if !chrome {
                // Score pill (and, in landscape, the rally) top left; on a letterboxed video, on the video's corner.
                VStack(alignment: .leading) {
                    HStack(spacing: 8) {
                        if !zoomed, let s = rallies.runningScore(at: t) {
                            pill(RacketPlayerText.score(s.us, s.them), weight: .bold)
                                .accessibilityIdentifier("racket.player.scorePill")
                        }
                        if landscape, !zoomed, let line = RacketPlayerCopy.compactRally(rallies, at: t) {
                            pill(line).accessibilityIdentifier("racket.player.rallyPill")
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer()
                }
                .padding(.leading, leading)
                .padding(.top, top)
                .ignoresSafeArea()
                // Mode labels top right (an active loop, rallies only, a speed other than 1×).
                if !zoomed {
                    VStack {
                        HStack(spacing: 8) {
                            Spacer()
                            ForEach(Array(RacketPlayerCopy.modeBadges(loopNumber: loopNumber(pb), ralliesOnly: onlyRallies,
                                                                       rate: hold.isHolding ? (hold.saved ?? 1) : pb.rate).enumerated()),
                                    id: \.offset) { k, b in
                                pill(b, tint: b.hasSuffix("×") ? SnappetColor.ink : SnappetColor.brand)
                                    .accessibilityIdentifier("racket.player.badge.\(k)")
                            }
                        }
                        Spacer()
                    }
                    .padding(.trailing, trailing).padding(.top, top)
                    .ignoresSafeArea()
                }
                if sideways && !landscape {
                    Text(RacketPlayerText.turnHint)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .position(x: fit.midX, y: fit.maxY + 40)
                        .ignoresSafeArea()
                        .accessibilityIdentifier("racket.player.turnHint")
                }
                // The thin progress line with rally segments.
                VStack {
                    Spacer()
                    progressLine(pb)
                }
                .padding(.bottom, 4)
            }
            if hold.isHolding {
                VStack {
                    pill(RacketPlayerText.holdLabel).accessibilityIdentifier("racket.player.holdLabel")
                    Spacer()
                }
                .padding(.top, chrome ? insets.top + (landscape ? 52 : 64) : top)
                .ignoresSafeArea()
            }
            if zoomed {
                VStack {
                    HStack(spacing: 8) {
                        Spacer()
                        pill(RacketPlayerText.zoom(zoom), weight: .bold).accessibilityIdentifier("racket.player.zoomLabel")
                        Button { resetZoom() } label: {
                            Text("Reset").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
                                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("racket.player.zoomReset")
                    }
                    Spacer()
                }
                .padding(.trailing, trailing).padding(.top, chrome ? insets.top + (landscape ? 52 : 64) : top - 4)
                .ignoresSafeArea()
            }
        }
    }

    private func progressLine(_ pb: RacketPlayback) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let p = duration > 0 ? (pb.position - ref.startSec) / duration : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 3)
                ForEach(Array(RacketPlayerBand.fractions(rallies, start: ref.startSec, end: ref.endSec).enumerated()), id: \.offset) { _, b in
                    Rectangle().fill(bandColor(b.band))
                        .frame(width: max(2, (b.to - b.from) * w), height: 3)
                        .offset(x: b.from * w)
                }
                RoundedRectangle(cornerRadius: 1).fill(SnappetColor.ink).frame(width: 2, height: 9)
                    .offset(x: min(max(0, p), 1) * w - 1)
            }
            .frame(height: 9)
        }
        .frame(height: 9)
        .padding(.horizontal, 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("racket.player.progress")
    }

    private func bandColor(_ b: RacketPlayerBand) -> Color {
        switch b {
        case .won: return SnappetColor.brand
        case .lost: return SnappetColor.textSecondary
        case .untagged: return SnappetColor.brand.opacity(0.35)
        }
    }

    private func rippleView(_ r: Ripple) -> some View {
        GeometryReader { g in
            let full = g.size
            let w = full.width * 0.42, h = full.height * 0.56
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: w * 2, height: h)
                    .position(x: r.side == .forward ? full.width : 0, y: full.height / 2)
                Text(RacketPlayerText.skip(r.total))
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(SnappetColor.ink)
                    .position(x: r.side == .forward ? full.width - w * 0.55 : w * 0.55, y: full.height / 2)
                    .accessibilityIdentifier("racket.player.skipLabel")
            }
        }
    }

    /// PlayerScrub: the time and the rally while dragging the strip.
    private func scrubReadout(_ pb: RacketPlayback) -> some View {
        VStack {
            VStack(spacing: 6) {
                Text(RacketPlayerText.clock(pb.position - ref.startSec))
                    .font(.system(size: 34, weight: .light).monospacedDigit()).foregroundStyle(SnappetColor.ink)
                    .accessibilityIdentifier("racket.player.scrubTime")
                if let l = RacketPlayerCopy.scrubLine(rallies, at: pb.position, sides: sides) {
                    Text(l.text).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(l.untagged ? SnappetColor.perfModerate : SnappetColor.ink)
                        .accessibilityIdentifier("racket.player.scrubRally")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 180)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: The controls (PlayerChrome · PlayerPaused · PlayerSpeed · PlayerNoRallies · PlayerEnd · PlayerLandscapeChrome)

    @ViewBuilder private func chromeLayer(_ pb: RacketPlayback, landscape: Bool) -> some View {
        ZStack {
            if !dragging {
                if pb.ended {
                    endButtons(pb)
                } else if !pb.playing, pb.loaded || downloading != nil {
                    Button { pb.play(); touched() } label: {
                        Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(SnappetColor.ink)
                            .frame(width: 76, height: 76)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(pb.player == nil && downloading != nil)
                    .opacity(downloading != nil ? 0.45 : 1)
                    .accessibilityLabel("Play")
                    .accessibilityIdentifier("racket.player.centerPlay")
                }
                VStack { topBar(pb, landscape: landscape); Spacer() }
            }
            if speedMenu {
                Color.black.opacity(0.001).ignoresSafeArea()
                    .onTapGesture { speedMenu = false; touched() }
                    .accessibilityHidden(true)
            }
            VStack {
                Spacer()
                if landscape { landscapeBar(pb) } else { bottomPanel(pb) }
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.player.controls")
    }

    private func topBar(_ pb: RacketPlayback, landscape: Bool) -> some View {
        ZStack {
            VStack(spacing: 1) {
                if landscape {
                    Text(RacketPlayerCopy.landscapeTitle(title, rallies, at: pb.position, loggedScore: unitScore?.label, missing: missing))
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        .accessibilityIdentifier("racket.player.title")
                } else {
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        .accessibilityIdentifier("racket.player.title")
                    Text(RacketPlayerCopy.subtitle(rallies, at: pb.position, loggedScore: unitScore?.label, missing: missing))
                        .font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                        .accessibilityIdentifier("racket.player.subtitle")
                }
            }
            .foregroundStyle(SnappetColor.ink)
            .padding(.horizontal, 110)
            HStack(spacing: 4) {
                Button { pb.stop(); dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        Text("Videos").font(.system(size: 16))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Videos")
                .accessibilityIdentifier("racket.player.back")
                Spacer()
                Button { pb.pause(); exporting = true } label: {
                    Text("Share").font(.system(size: 16)).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(missing)
                .accessibilityIdentifier("racket.player.share")
                // Edit mode (prompt 254): pauses and opens over the player on the same video.
                Button { pb.pause(); editing = true; touched() } label: {
                    Text("Edit").font(.system(size: 16, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(missing)
                .accessibilityIdentifier("racket.player.edit")
            }
            .foregroundStyle(SnappetColor.brand)
            .tint(SnappetColor.brand)
            .padding(.horizontal, 10)
        }
        .frame(height: landscape ? 46 : 52)
        .background(Color.black.opacity(0.6).ignoresSafeArea(edges: .top))
    }

    private func bottomPanel(_ pb: RacketPlayback) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(labelLine(pb)).font(.system(size: 13, weight: .semibold)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                    .accessibilityIdentifier("racket.player.label")
                Spacer(minLength: 8)
                Text(RacketPlayerText.timeLine(pb.position - ref.startSec, of: duration))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.player.time")
            }
            .opacity(dragging ? 0 : 1)
            HStack(spacing: 6) {
                playPauseButton(pb).opacity(dragging ? 0 : 1)
                filmstrip(pb)
                muteButton(pb).opacity(dragging ? 0 : 1)
            }
            HStack(spacing: 18) {
                transportCircle("backward.end.fill", label: "Previous rally", id: "racket.player.prevRally",
                                enabled: rallies.previousStart(from: pb.position) != nil) { previousRally(pb) }
                speedButton(pb, trailing: false)
                transportCircle("forward.end.fill", label: "Next rally", id: "racket.player.nextRally",
                                enabled: rallies.nextStart(from: pb.position) != nil) { nextRally(pb) }
            }
            .opacity(dragging ? 0 : 1)
            if rallies.isEmpty && !dragging {
                HStack(spacing: 10) {
                    Button { pb.pause(); onFindRallies?() } label: {
                        Text("Find rallies").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(SnappetColor.brand, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(onFindRallies == nil)
                    .opacity(onFindRallies == nil ? 0.4 : 1)
                    .accessibilityIdentifier("racket.player.findRallies")
                    Button { pb.pause(); onMarkByHand?() } label: {
                        Text("Mark by hand").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.hairline))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onMarkByHand == nil)
                    .accessibilityIdentifier("racket.player.markByHand")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
        .background(Color.black.opacity(dragging ? 0.35 : 0.6).ignoresSafeArea(edges: .bottom))
    }

    private func landscapeBar(_ pb: RacketPlayback) -> some View {
        HStack(spacing: 8) {
            playPauseButton(pb)
            transportCircle("backward.end.fill", label: "Previous rally", id: "racket.player.prevRally",
                            enabled: rallies.previousStart(from: pb.position) != nil) { previousRally(pb) }
            filmstrip(pb)
            transportCircle("forward.end.fill", label: "Next rally", id: "racket.player.nextRally",
                            enabled: rallies.nextStart(from: pb.position) != nil) { nextRally(pb) }
            speedButton(pb, trailing: true)
            muteButton(pb)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.6).ignoresSafeArea(edges: [.bottom, .horizontal]))
    }

    private func labelLine(_ pb: RacketPlayback) -> String {
        if downloading != nil { return RacketPlayerText.openingLine }
        if pb.ended { return RacketPlayerCopy.endLine(title, score: unitScore) }
        return RacketPlayerCopy.rallyLine(rallies, at: pb.position, sides: sides)
    }

    private func playPauseButton(_ pb: RacketPlayback) -> some View {
        Button { pb.toggle(); touched() } label: {
            Image(systemName: pb.playing ? "pause.fill" : "play.fill").font(.system(size: 18))
                .foregroundStyle(SnappetColor.ink).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pb.playing ? "Pause" : "Play")
        .accessibilityIdentifier("racket.player.playPause")
    }

    private func muteButton(_ pb: RacketPlayback) -> some View {
        Button { pb.muted.toggle(); touched() } label: {
            Image(systemName: pb.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 17))
                .foregroundStyle(SnappetColor.ink).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pb.muted ? "Unmute" : "Mute")
        .accessibilityIdentifier("racket.player.mute")
    }

    private func transportCircle(_ symbol: String, label: String, id: String, enabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button { action(); touched() } label: {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(SnappetColor.ink)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(SnappetColor.hairline, lineWidth: 1))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func speedButton(_ pb: RacketPlayback, trailing: Bool) -> some View {
        Button { speedMenu.toggle(); touched() } label: {
            Text(RacketPlayerText.speed(hold.isHolding ? (hold.saved ?? 1) : pb.rate))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(minWidth: 56, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SnappetColor.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed")
        .accessibilityValue(RacketPlayerText.speed(pb.rate))
        .accessibilityIdentifier("racket.player.speed")
        .overlay(alignment: trailing ? .bottomTrailing : .bottom) {
            if speedMenu { speedMenuView(pb).offset(y: -54) }
        }
    }

    /// PlayerSpeed: the speeds, then Loop this rally and Rallies only.
    private func speedMenuView(_ pb: RacketPlayback) -> some View {
        let loopTarget = rallies.loopTarget(at: pb.position)
        return VStack(spacing: 0) {
            ForEach(RacketPlayerSpeed.options, id: \.self) { r in
                menuRow(RacketPlayerText.speed(r), selected: pb.rate == r, id: "racket.player.speed.\(RacketPlayerSpeed.id(r))") {
                    pb.rate = r
                }
                Divider().overlay(SnappetColor.hairline)
            }
            menuRow("Loop this rally", selected: pb.loop != nil, enabled: loopTarget != nil, id: "racket.player.loop") {
                if pb.loop != nil { pb.loop = nil } else if let l = loopTarget {
                    pb.loop = l.range
                    if pb.position < l.range.lowerBound || pb.position >= l.range.upperBound { pb.seek(to: l.range.lowerBound) }
                }
            }
            Divider().overlay(SnappetColor.hairline)
            menuRow("Rallies only", selected: onlyRallies, enabled: !rallies.isEmpty, id: "racket.player.ralliesOnly") {
                onlyRallies.toggle()
            }
        }
        .frame(width: 180)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.player.speedMenu")
    }

    private func menuRow(_ label: String, selected: Bool, enabled: Bool = true, id: String,
                         action: @escaping () -> Void) -> some View {
        Button { action(); speedMenu = false; touched() } label: {
            HStack(spacing: 6) {
                Text(selected ? "\(label) ✓" : label)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? SnappetColor.brand : SnappetColor.ink)
                Spacer()
            }
            .padding(.horizontal, 14).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// PlayerEnd: Replay, and the next game when there is one.
    private func endButtons(_ pb: RacketPlayback) -> some View {
        HStack(spacing: 36) {
            endCircle("arrow.counterclockwise", label: "Replay", id: "racket.player.replay") {
                if onlyRallies, let first = rallies.rallies.first { pb.seek(to: first.startSec) } else { pb.seek(to: ref.startSec) }
                pb.play()
            }
            if let next = nextPart, let onNextPart {
                endCircle("forward.end.fill", label: RacketPlayerText.title(next.title), id: "racket.player.nextGame") {
                    pb.stop()
                    onNextPart(next)
                }
            }
        }
    }

    private func endCircle(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); touched() }) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    .frame(width: 64, height: 64)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                Text(label).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Filmstrip

    private func filmstrip(_ pb: RacketPlayback) -> some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let strip = RacketFilmstrip(start: ref.startSec, end: ref.endSec, visibleWidth: Double(w))
            let aspect = (pb.videoSize ?? pb.poster?.size).map { $0.width / max(1, $0.height) } ?? (9.0 / 16.0)
            let tileW = max(16, h * aspect)
            let tiles = strip.tileTimes(tileWidth: Double(tileW)).count
            let bands = rallies.isEmpty
            ZStack {
                Canvas { ctx, size in
                    let origin = size.width / 2 + strip.offset(at: pb.position)
                    // Frames.
                    for k in 0..<tiles {
                        let x = origin + Double(k) * tileW
                        guard x + tileW >= 0, x <= size.width else { continue }
                        let rect = CGRect(x: x, y: 0, width: tileW - 1, height: size.height)
                        let i = RacketFilmstrip.thumbnailIndex(tile: k, tiles: tiles, count: thumbnails.count)
                        if i < thumbnails.count, let img = thumbnails[i] {
                            ctx.draw(Image(uiImage: img), in: rect)
                        } else {
                            ctx.fill(Path(rect), with: .color(Color(white: 0.18)))
                        }
                    }
                    // Rally bands: won accent, lost grey, untagged dashed.
                    if !bands {
                        for r in rallies.rallies {
                            let a = origin + strip.x(at: r.startSec), b = origin + strip.x(at: r.endSec)
                            guard b >= 0, a <= size.width else { continue }
                            let rect = CGRect(x: a, y: 1, width: max(3, b - a), height: size.height - 2)
                            let shape = Path(roundedRect: rect, cornerRadius: 4)
                            switch RacketPlayerBand.of(r) {
                            case .won:
                                ctx.fill(shape, with: .color(SnappetColor.brand.opacity(0.35)))
                                ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)), with: .color(SnappetColor.brand))
                            case .lost:
                                ctx.fill(shape, with: .color(Color.white.opacity(0.22)))
                                ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)), with: .color(SnappetColor.textSecondary))
                            case .untagged:
                                ctx.stroke(shape, with: .color(SnappetColor.brand), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // The fixed centre playhead.
                RoundedRectangle(cornerRadius: 1).fill(SnappetColor.ink).frame(width: 3, height: h + 16)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in dragChanged(pb, strip: strip, translation: Double(v.translation.width)) }
                .onEnded { v in dragEnded(pb, strip: strip, translation: Double(v.translation.width)) })
            .task(id: "\(tiles)-\(pb.player != nil)") { await loadThumbnails(pb, tiles: tiles) }
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityLabel("Timeline, \(rallies.count) rallies")
        .accessibilityValue(RacketPlayerText.timeLine(pb.position - ref.startSec, of: duration))
        .accessibilityAdjustableAction { dir in
            skip(pb, dir == .increment ? RacketPlayerTaps.skipSec : -RacketPlayerTaps.skipSec)
        }
        .accessibilityIdentifier("racket.player.strip")
    }

    private func dragChanged(_ pb: RacketPlayback, strip: RacketFilmstrip, translation: Double) {
        if !dragging {
            dragging = true
            speedMenu = false
            dragFrom = pb.position
            dragWasPlaying = pb.playing
            lastDrag = nil
        }
        let t = strip.time(dragging: translation, from: dragFrom)
        let now = Date()
        var speed = 0.0
        if let l = lastDrag {
            let dt = now.timeIntervalSince(l.at)
            if dt > 0 { speed = (t - l.t) / dt }
        }
        lastDrag = (t, now)
        pb.scrub(to: t, tolerance: RacketFilmstrip.dragTolerance(videoSecPerSec: speed))
        clearLoopIfOutside(pb, t)
    }

    private func dragEnded(_ pb: RacketPlayback, strip: RacketFilmstrip, translation: Double) {
        let t = strip.time(dragging: translation, from: dragFrom)
        pb.seek(to: t)
        dragging = false
        if dragWasPlaying { pb.play() }
        touched()
    }

    /// Frames for the strip: as many as tiles (at most 60), a few at a time so the first ones show at once.
    private func loadThumbnails(_ pb: RacketPlayback, tiles: Int) async {
        guard let player = pb.player, tiles > 0 else { return }
        let count = min(60, tiles)
        guard thumbsDone != count else { return }
        let times = RacketScrub.thumbnailTimes(start: 0, end: duration, count: count)
        var out = thumbnails.count == count ? thumbnails : [UIImage?](repeating: nil, count: count)
        // Centre-out from the playhead: the frames you see first come first; frames already made are kept.
        let here = Int(((pb.position - ref.startSec) / max(1, duration) * Double(count)).rounded(.down))
        let order = (0..<count).filter { out[$0] == nil }.sorted { abs($0 - here) < abs($1 - here) }
        thumbnails = out
        for chunk in stride(from: 0, to: order.count, by: 6).map({ Array(order[$0..<min(order.count, $0 + 6)]) }) {
            if Task.isCancelled { return }
            let imgs = await RacketVideoLibrary.shared.thumbnails(player, times: chunk.map { times[$0] }, maxSide: 120)
            for (k, i) in chunk.enumerated() where k < imgs.count { out[i] = imgs[k] }
            thumbnails = out
        }
        if !Task.isCancelled { thumbsDone = count }
    }

    // MARK: Missing (PlayerMissing)

    private var missingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RacketPlayerText.missingTitle).font(.system(size: 18, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .accessibilityIdentifier("racket.player.missing.title")
            Text(RacketPlayerText.missingBody).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Relinking a recording to a video chosen again from Photos is deferred (prompt 253): a recording can
            // span several Photos videos, so a single pick can't safely replace them. The button says so.
            Button {} label: {
                VStack(spacing: 2) {
                    Text("Choose it again from Photos").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SnappetColor.ink.opacity(0.75))
                    Text("Not available yet").font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(SnappetColor.brand.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .padding(.top, 4)
            .accessibilityIdentifier("racket.player.missing.relink")
            Button { dismiss() } label: {
                Text("Keep the stats only").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.hairline))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("racket.player.missing.keep")
        }
        .padding(16)
        .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(SnappetColor.hairline))
        .padding(.horizontal, 24)
    }

    // MARK: Small pieces

    private func pill(_ text: String, weight: Font.Weight = .semibold, tint: Color = SnappetColor.ink) -> some View {
        Text(text).font(.system(size: 13, weight: weight)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize()
    }

    // MARK: Actions

    private func touched() { touches &+= 1 }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
        speedMenu = false
        touched()
    }

    private func handleTap(_ pb: RacketPlayback, x: Double, width: Double) {
        for a in taps.tap(x: x, width: width, at: CACurrentMediaTime()) {
            switch a {
            case .toggleControls: toggleChrome()
            case .skip(let s): skip(pb, s)
            case .ripple(let side, let total):
                ripple = Ripple(side: side, total: total, token: (ripple?.token ?? 0) + 1)
            }
        }
    }

    private func skip(_ pb: RacketPlayback, _ sec: Double) {
        let t = RacketPlaybackPolicy.clamp(pb.position + sec, ref.startSec, ref.endSec)
        pb.seek(to: t)
        clearLoopIfOutside(pb, t)
        touched()
    }

    private func previousRally(_ pb: RacketPlayback) {
        guard let t = rallies.previousStart(from: pb.position) else { return }
        pb.seek(to: t)
        clearLoopIfOutside(pb, t)
    }

    private func nextRally(_ pb: RacketPlayback) {
        guard let t = rallies.nextStart(from: pb.position) else { return }
        pb.seek(to: t)
        clearLoopIfOutside(pb, t)
    }

    private func clearLoopIfOutside(_ pb: RacketPlayback, _ t: Double) {
        if let l = pb.loop, !(t >= l.lowerBound - 0.05 && t < l.upperBound) { pb.loop = nil }
    }

    private func loopNumber(_ pb: RacketPlayback) -> Int? {
        guard let l = pb.loop else { return nil }
        return rallies.rallies.firstIndex { abs($0.startSec - l.lowerBound) < 0.01 }.map { $0 + 1 }
    }

    private func beginHold(_ pb: RacketPlayback) {
        let r = hold.begin(rate: pb.rate, playing: pb.playing)
        pb.rate = r.rate
        if r.play && !pb.playing { pb.play() }
        Haptics.tap()
        touched()
    }

    private func endHold(_ pb: RacketPlayback) {
        guard let r = hold.end() else { return }
        pb.rate = r.rate
        if r.pause { pb.pause() }
        touched()
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            pan = .zero
        }
        touched()
    }
}

// MARK: - The gesture surface (UIKit recognizers: an instant single tap, hold, pinch, pan)

/// Taps are handled on touch-up with no wait for a double tap (the pure `RacketPlayerTaps` turns a quick second tap
/// into a skip). Hold is a long press (0.4 s). Pinch and pan run together; pan only while zoomed, so an unzoomed
/// drag never fights the navigation's swipe.
struct RacketPlayerGestureSurface: UIViewRepresentable {
    enum Phase { case began, changed, ended }

    var zoomed: Bool
    var onTap: (Double, Double) -> Void
    var onHold: (Bool) -> Void
    var onPinch: (Double, Phase) -> Void
    var onPan: (CGSize, Phase) -> Void

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RacketPlayerGestureSurface
        init(_ p: RacketPlayerGestureSurface) { parent = p }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            parent.onTap(Double(g.location(in: v).x), Double(v.bounds.width))
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: parent.onHold(true)
            case .ended, .cancelled, .failed: parent.onHold(false)
            default: break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: parent.onPinch(Double(g.scale), .began)
            case .changed: parent.onPinch(Double(g.scale), .changed)
            case .ended, .cancelled, .failed: parent.onPinch(Double(g.scale), .ended)
            default: break
            }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            let size = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began: parent.onPan(size, .began)
            case .changed: parent.onPan(size, .changed)
            case .ended, .cancelled, .failed: parent.onPan(size, .ended)
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UIPanGestureRecognizer { return parent.zoomed }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
                || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        long.minimumPressDuration = 0.4
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: long)
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        for g in [long, tap, pinch, pan] as [UIGestureRecognizer] {
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
    }
}
