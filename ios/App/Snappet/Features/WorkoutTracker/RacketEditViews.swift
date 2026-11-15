import SwiftUI
import AVFoundation
import UIKit

// MARK: - Racket player, Edit mode (prompt 254, issue #448 part 1 "Edit")
//
// Boards EditRallies, EditSelected, EditTrim, EditMarking, EditShots, EditSport, EditLooks, EditScore, EditEmpty,
// EditFinding, EditDiscard, EditList. Apple Photos' video Edit mode: the video on top, a transport row, a time ruler and a
// tall filmstrip scrolling under a fixed centre playhead; tabs Rallies / Looks / Score. Every edit goes into the pure
// working copy `RacketEditSession` (Undo / Redo); Done writes it to the session, Cancel drops it.

struct RacketEditScreen: View {
    let store: RacketVideoStore
    let ref: RacketPartRef
    let playback: RacketPlayback
    /// The analysis view (tags over video, other apps' suggestions), from the rally list.
    var onAnalysis: (() -> Void)? = nil
    /// "Compare ChatGPT suggestions" when a reply waits, from the rally list.
    var compare: (label: String, action: () -> Void)? = nil
    let onClose: () -> Void

    enum Tab: String, CaseIterable { case rallies, looks, score
        var label: String { rawValue.capitalized }
    }

    @State private var session: RacketEditSession?
    @State private var tab: Tab = .rallies
    @State private var selected: UUID?
    /// The handle last touched (EditTrim; the nudges move it).
    @State private var edge: RacketEditSession.Edge?
    @State private var handleFrom: Double = 0
    @State private var markStart: Double?
    @State private var problem: String?
    @State private var listOpen = false
    @State private var filter: RacketEditListFilter = .all
    @State private var shotsOpen = false
    @State private var pps: Double = 18
    @State private var ppsAtPinch: Double?
    @State private var dragFrom: Double?
    @State private var dragWasPlaying = false
    @State private var scanID: UUID?
    @State private var scanPaused = false
    @State private var scanFound: Int?
    @State private var scanTouchedStore = false
    @State private var askDiscard = false
    @State private var thumbs: [UIImage?] = []
    @State private var thumbsCount = 0
    @State private var lookThumbs: [RacketLook: UIImage] = [:]
    @State private var detail: RacketTagDetail?
    @State private var rules = false
    @State private var scoreIndex = 0
    @State private var originalPart: [RacketRally] = []
    @State private var configured = false

    private var ex: SessionExercise? { store.ex(ref.exerciseID) }
    private var log: RacketRecordingLog? { ex?.racketRecordingLog }
    private var sport: RacketSport { ex?.racketSport ?? .tableTennis }
    private var doubles: Bool { ex?.isDoubles ?? false }
    private var sides: (us: String, them: String) { RacketWatchCopy.sides(opponent: ex?.opponent, doubles: doubles) }
    private var position: Double { playback.position }
    private var rel: Double { playback.position - ref.startSec }
    private var current: RacketRally? { session?.rally(selected) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let s = session {
                video(s)
                switch tab {
                case .rallies: ralliesTab(s)
                case .looks: looksTab(s)
                case .score: scoreTab(s)
                }
            }
            Spacer(minLength: 0)
            tabBar
        }
        .background(Color.black.ignoresSafeArea())
        // EditDiscard as a real bottom sheet (a hand-made modal overlay read as an "Alert" to XCTest and blocked taps
        // on the phone, prompt 254 follow-up).
        .sheet(isPresented: $askDiscard) { if let s = session { discardSheet(s) } }
        // The boards define Edit in portrait only: it stays upright however the phone is held (the player rotates).
        .portraitOnly()
        .preferredColorScheme(.dark)
        .tint(SnappetColor.brand)
        .sheet(isPresented: $rules) { RacketRulesSheet(sport: sport) }
        .sheet(item: $detail) { d in if let r = current { detailSheet(d, rally: r) } }
        .task { configure() }
        .task(id: scanID) { await watchScan() }
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        let part = RacketRallyMarking.inRange(log?.allRallies ?? [], ref.startSec, ref.endSec)
        originalPart = part
        let always = UserDefaults.standard.string(forKey: RacketLookStore.alwaysKey).flatMap(RacketLook.init(rawValue:))
        let look = RacketLookStore.resolve(partStart: ref.startSec, log: log, always: always)
        session = RacketEditSession(rallies: part, lo: ref.startSec, hi: ref.endSec, look: look.look, lookScope: look.scope)
        scoreIndex = ref.setIndex ?? 0
        playback.pause()
        selected = nil
    }

    private func mutate(_ body: (inout RacketEditSession) -> Void) {
        guard var s = session else { return }
        body(&s)
        session = s
        if selected != nil, s.rally(selected)?.isRally != true { selected = nil; edge = nil; shotsOpen = false }
    }

    // MARK: Top bar · Cancel / Undo / Redo / Done

    private var topBar: some View {
        HStack {
            Button("Cancel") { cancel() }
                .font(.system(size: 17)).frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("racket.edit.cancel")
            Spacer()
            HStack(spacing: 6) {
                Button { mutate { $0.undo() }; Haptics.tap() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }
                .disabled(session?.canUndo != true)
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("racket.edit.undo")
                Button { mutate { $0.redo() }; Haptics.tap() } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44)
                }
                .disabled(session?.canRedo != true)
                .accessibilityLabel("Redo")
                .accessibilityIdentifier("racket.edit.redo")
            }
            .foregroundStyle(SnappetColor.ink)
            Spacer()
            Button("Done") { done() }
                .font(.system(size: 17, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("racket.edit.done")
        }
        .foregroundStyle(SnappetColor.brand)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color.black)
    }

    // MARK: Video

    private var videoHeight: CGFloat { listOpen || tab == .score ? 260 : 300 }

    private func video(_ s: RacketEditSession) -> some View {
        ZStack(alignment: .top) {
            Group {
                if let player = playback.player {
                    RacketTurned(turns: playback.quarterTurns) {
                        RacketPlayerLayerView(player: player, target: playback.position - playback.partStart)
                    }
                } else if let poster = playback.poster {
                    RacketTurned(turns: playback.quarterTurns) {
                        Image(uiImage: poster).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ZStack {
                        Color(white: 0.11)
                        Text(playback.loadState.line ?? "No video saved for this recording")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("racket.player.standIn")
                    }
                }
            }
            .frame(maxWidth: .infinity).frame(height: videoHeight)
            .clipped()
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                if tab == .looks { playback.showOriginal = pressing }
            })
            .accessibilityElement()
            .accessibilityLabel(tab == .looks ? "Video, \(s.state.look.label)" : "Video")
            .accessibilityAction(named: "Show the original") { playback.showOriginal.toggle() }
            .accessibilityIdentifier("racket.edit.video")
            HStack {
                if tab == .looks {
                    Spacer()
                    pill(playback.showOriginal ? "Original" : "Hold the video to see the original")
                        .accessibilityIdentifier("racket.edit.holdHint")
                    Spacer()
                } else if let e = edge, let r = current, let n = s.number(of: r.id) {
                    Spacer()
                    pill(e == .start ? "Start of rally \(n)" : "End of rally \(n)").accessibilityIdentifier("racket.edit.trimPill")
                    Spacer()
                } else if tab == .rallies, !shotsOpen, markStart == nil,
                          let sc = RacketPlayerRallies(s.visible).runningScore(at: position) {
                    pill(RacketPlayerText.score(sc.us, sc.them), bold: true)
                    Spacer()
                }
            }
            .padding(10)
        }
        .frame(height: videoHeight)
        .background(Color(white: 0.11))
    }

    // MARK: Rallies tab

    @ViewBuilder private func ralliesTab(_ s: RacketEditSession) -> some View {
        if listOpen {
            listView(s)
        } else {
            let sportRows = current != nil && edge == nil && !shotsOpen && (sport.usesSets || doubles)
            if edge != nil, let r = current {
                trimReadout(r)
            } else if shotsOpen, let r = current {
                HStack {
                    Text("Rally \(s.number(of: r.id) ?? 0) shots").font(.system(size: 15, weight: .semibold))
                        .accessibilityIdentifier("racket.edit.shotsTitle")
                    Spacer()
                    Text("Shot finding: not available yet").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.edit.shotsNotYet")
                }
                .padding(.horizontal, 14).padding(.top, 10)
            } else if !sportRows {
                transport(s)
            }
            ruler.padding(.top, sportRows ? 10 : 2)
            strip(s)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if markStart != nil {
                        markingPanel
                    } else if edge != nil, current != nil {
                        trimPanel
                    } else if shotsOpen, let r = current {
                        shotsPanel(r)
                    } else if let r = current {
                        inspector(s, r)
                    } else if scanID != nil || scanFound != nil {
                        findingPanel(s)
                    } else if s.visible.isEmpty {
                        emptyPanel
                    } else {
                        restPanel(s)
                    }
                    if let problem {
                        Text(problem).font(SnappetType.detail).foregroundStyle(SnappetColor.perfModerate)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.edit.problem")
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
            }
        }
    }

    private func transport(_ s: RacketEditSession) -> some View {
        ZStack {
            Text(RacketPlayerText.tenths(rel)).font(.system(size: 20).monospacedDigit()).foregroundStyle(SnappetColor.ink)
                .accessibilityIdentifier("racket.edit.time")
            HStack {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.system(size: 16))
                        .foregroundStyle(SnappetColor.ink).frame(width: 44, height: 44)
                        .overlay(Circle().strokeBorder(SnappetColor.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.playing ? "Pause" : "Play")
                .accessibilityIdentifier("racket.edit.play")
                Spacer()
                if let m = markStart {
                    Text(RacketEditMark.line(start: m, now: position)).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SnappetColor.perfHard)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(SnappetColor.perfHard.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("racket.edit.marking")
                } else {
                    stepButton("chevron.left", label: "Back one frame", id: "racket.edit.stepBack") {
                        playback.seek(to: position - RacketEditZoom.frameSec)
                    }
                    stepButton("chevron.right", label: "Forward one frame", id: "racket.edit.stepForward") {
                        playback.seek(to: position + RacketEditZoom.frameSec)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 8)
    }

    private func stepButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button { playback.pause(); action() } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// EditTrim: "Start · 08:10.6 · Length 6.6 s".
    private func trimReadout(_ r: RacketRally) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(edge == .end ? "End" : "Start").font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.edit.trimEdge")
            Spacer()
            Text(RacketPlayerText.tenths((edge == .end ? r.endSec : r.startSec) - ref.startSec))
                .font(.system(size: 20).monospacedDigit())
                .accessibilityIdentifier("racket.edit.trimValue")
            Spacer()
            Text("Length " + RacketPlayerText.seconds(r.durationSec)).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.edit.length")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
    }

    private var ruler: some View {
        GeometryReader { g in
            let w = g.size.width
            let step = RacketEditRuler.step(pointsPerSec: pps)
            let half = Double(w) / 2 / pps
            ZStack(alignment: .topLeading) {
                ForEach(RacketEditRuler.ticks(from: max(ref.startSec, position - half - step), to: min(ref.endSec, position + half + step),
                                              step: step), id: \.self) { t in
                    let lx = w / 2 + (t - position) * pps
                    // Only labels that fit inside the strip's width (no half labels at the edges).
                    if lx > 18, lx < w - 18 {
                        Text(RacketPlayerText.clock(t - ref.startSec)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize()
                            .position(x: lx, y: 8)
                    }
                }
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 14)
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: The strip

    private func strip(_ s: RacketEditSession) -> some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let film = RacketFilmstrip(start: ref.startSec, end: ref.endSec, pointsPerSec: pps)
            let aspect = (playback.videoSize ?? playback.poster?.size).map { $0.width / max(1, $0.height) } ?? (9.0 / 16.0)
            let tileW = max(18, (h - 8) * aspect)
            let x: (Double) -> CGFloat = { t in w / 2 + (t - position) * pps }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let origin = size.width / 2 + film.offset(at: position)
                    let tiles = film.tileTimes(tileWidth: Double(tileW))
                    let total = max(0.001, ref.endSec - ref.startSec)
                    for (k, t) in tiles.enumerated() {
                        let tx = origin + Double(k) * tileW
                        guard tx + tileW >= 0, tx <= size.width else { continue }
                        let rect = CGRect(x: tx, y: 4, width: tileW - 1, height: size.height - 8)
                        let i = thumbs.isEmpty ? -1 : min(thumbs.count - 1, Int((t - ref.startSec) / total * Double(thumbs.count)))
                        if i >= 0, let img = thumbs[i] {
                            ctx.draw(Image(uiImage: img), in: rect)
                        } else {
                            ctx.fill(Path(rect), with: .color(Color(white: 0.18)))
                        }
                    }
                    for r in s.visible {
                        let a = x(r.startSec), b = x(r.endSec)
                        guard b >= 0, a <= size.width else { continue }
                        let rect = CGRect(x: a, y: 5, width: max(3, b - a), height: size.height - 10)
                        let shape = Path(roundedRect: rect, cornerRadius: 4)
                        switch RacketPlayerBand.of(r) {
                        case .won:
                            ctx.fill(shape, with: .color(SnappetColor.brand.opacity(0.35)))
                            ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)), with: .color(SnappetColor.brand))
                        case .lost:
                            ctx.fill(shape, with: .color(Color.white.opacity(0.22)))
                            ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 3, width: rect.width, height: 3)), with: .color(SnappetColor.textSecondary))
                        case .untagged:
                            ctx.stroke(shape, with: .color(r.isGuess ? SnappetColor.perfModerate : SnappetColor.brand),
                                       style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        }
                    }
                    if let m = markStart {
                        let a = x(min(m, position)), b = x(max(m, position))
                        let rect = CGRect(x: a, y: 5, width: max(2, b - a), height: size.height - 10)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(SnappetColor.perfHard.opacity(0.35)))
                        ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(SnappetColor.perfHard), lineWidth: 1.5)
                    }
                    if let r = current {
                        let rect = CGRect(x: x(r.startSec), y: 2, width: max(4, x(r.endSec) - x(r.startSec)), height: size.height - 4)
                        ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(RacketEditColor.trim), lineWidth: 3)
                    }
                }
                .contentShape(Rectangle())
                .gesture(stripDrag(w: Double(w)))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        if ppsAtPinch == nil { ppsAtPinch = pps }
                        pps = RacketEditZoom.clamp((ppsAtPinch ?? pps) * v.magnification, visibleWidth: Double(w),
                                                   duration: ref.endSec - ref.startSec)
                    }
                    .onEnded { _ in ppsAtPinch = nil })
                .simultaneousGesture(SpatialTapGesture().onEnded { v in tapStrip(s, x: Double(v.location.x), w: Double(w)) })
                if let r = current, markStart == nil {
                    handle(.start, r, x: x(r.startSec), h: h, number: s.number(of: r.id) ?? 0)
                    handle(.end, r, x: x(r.endSec), h: h, number: s.number(of: r.id) ?? 0)
                }
                RoundedRectangle(cornerRadius: 1).fill(SnappetColor.ink).frame(width: 3, height: h + 6)
                    .position(x: w / 2, y: h / 2)
                    .allowsHitTesting(false)
            }
            .task(id: "\(Int(w))-\(playback.player != nil)") { await loadThumbs(width: Double(w)) }
        }
        .frame(height: 64)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.edit.strip")
    }

    private func stripDrag(w: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragFrom == nil { dragFrom = position; dragWasPlaying = playback.playing && markStart == nil }
                let film = RacketFilmstrip(start: ref.startSec, end: ref.endSec, pointsPerSec: pps)
                let t = film.time(dragging: Double(v.translation.width), from: dragFrom ?? position)
                if markStart != nil { playback.seek(to: t); if !playback.playing { playback.play() } } else {
                    playback.scrub(to: t, tolerance: 0)
                }
            }
            .onEnded { v in
                let film = RacketFilmstrip(start: ref.startSec, end: ref.endSec, pointsPerSec: pps)
                let t = film.time(dragging: Double(v.translation.width), from: dragFrom ?? position)
                playback.seek(to: t)
                if dragWasPlaying { playback.play() }
                dragFrom = nil
            }
    }

    /// Tap a rally to select it; tap off it to let go (and leave trimming).
    private func tapStrip(_ s: RacketEditSession, x: Double, w: Double) {
        guard markStart == nil else { return }
        let t = position + (x - w / 2) / pps
        let hit = s.visible.first { t >= $0.startSec && t < $0.endSec }
        edge = nil
        shotsOpen = false
        problem = nil
        selected = hit?.id
        if hit != nil { Haptics.tap() }
    }

    private func handle(_ e: RacketEditSession.Edge, _ r: RacketRally, x: CGFloat, h: CGFloat, number: Int) -> some View {
        let edgeTime = e == .start ? r.startSec : r.endSec
        return RoundedRectangle(cornerRadius: 4)
            .fill(RacketEditColor.trim)
            .frame(width: 14, height: h)
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.7)).frame(width: 2, height: 14))
            .frame(width: 44, height: h)
            .contentShape(Rectangle())
            .position(x: x + (e == .start ? -7 : 7), y: h / 2)
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if edge != e || dragFrom == nil {
                        edge = e
                        dragFrom = edgeTime
                        handleFrom = edgeTime
                        playback.pause()
                        mutate { $0.beginLive() }
                    }
                    let target = (dragFrom ?? edgeTime) + Double(v.translation.width) / pps
                    var landed: Double?
                    mutate { landed = $0.trim(r.id, e, to: target) }
                    if let t = landed {
                        if RacketEditZoom.crossedSecond(from: handleFrom - ref.startSec, to: t - ref.startSec) { Haptics.tap() }
                        handleFrom = t
                        playback.scrub(to: t, tolerance: 0)
                    }
                }
                .onEnded { _ in
                    mutate { $0.endLive() }
                    dragFrom = nil
                    if let r2 = session?.rally(r.id) { playback.seek(to: e == .start ? r2.startSec : r2.endSec) }
                })
            .accessibilityElement()
            .accessibilityLabel(e == .start ? "Start of rally \(number)" : "End of rally \(number)")
            .accessibilityValue(RacketPlayerText.tenths(edgeTime - ref.startSec))
            .accessibilityAdjustableAction { dir in nudge(e, r.id, dir == .increment ? 0.2 : -0.2) }
            .accessibilityAction(named: "Back 1 second") { nudge(e, r.id, -1) }
            .accessibilityAction(named: "Forward 1 second") { nudge(e, r.id, 1) }
            .accessibilityIdentifier("racket.edit.handle.\(e.rawValue)")
    }

    private func nudge(_ e: RacketEditSession.Edge, _ id: UUID, _ d: Double) {
        edge = e
        var landed: Double?
        mutate { landed = $0.nudge(id, e, by: d) }
        if let t = landed { playback.seek(to: t); Haptics.tap() }
    }

    private func loadThumbs(width: Double) async {
        guard let player = playback.player, width > 0 else { return }
        let count = 60
        guard thumbsCount != count else { return }
        let duration = ref.endSec - ref.startSec
        let times = RacketScrub.thumbnailTimes(start: 0, end: duration, count: count)
        var out = [UIImage?](repeating: nil, count: count)
        thumbs = out
        let here = Int(((position - ref.startSec) / max(1, duration) * Double(count)).rounded(.down))
        let order = (0..<count).sorted { abs($0 - here) < abs($1 - here) }
        for chunk in stride(from: 0, to: count, by: 6).map({ Array(order[$0..<min(count, $0 + 6)]) }) {
            if Task.isCancelled { return }
            let imgs = await RacketVideoLibrary.shared.thumbnails(player, times: chunk.map { times[$0] }, maxSide: 120)
            for (k, i) in chunk.enumerated() where k < imgs.count { out[i] = imgs[k] }
            thumbs = out
        }
        thumbsCount = count
    }

    // MARK: Panels

    /// EditRallies: + Rally, Split, Find rallies, the hint, "21 rallies · 19 tagged", List.
    private func restPanel(_ s: RacketEditSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                primaryButton("+ Rally", id: "racket.edit.addRally") { startMark(s) }
                secondaryButton("Split", id: "racket.edit.split", enabled: s.splittable(at: position) != nil) {
                    mutate { _ = $0.split(at: position) }
                    Haptics.tap()
                }
                secondaryButton("Find rallies", id: "racket.edit.find", enabled: model != nil) { findRallies() }
            }
            Text("Drag the strip to move through the video. Pinch it to zoom in or out. Tap a rally to select it.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.edit.hint")
            HStack {
                Text(s.countLine).font(.system(size: 14, weight: .semibold)).accessibilityIdentifier("racket.edit.count")
                Spacer()
                Button("List") { listOpen = true; playback.pause() }
                    .font(.system(size: 15, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("racket.edit.list")
            }
        }
    }

    /// EditEmpty: no rallies yet.
    private var emptyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            primaryButton("+ Rally", id: "racket.edit.addRally") { if let s = session { startMark(s) } }
            secondaryButton("Find rallies", id: "racket.edit.find", enabled: model != nil) { findRallies() }
            Text("Find rallies scans this video on the phone. It is a basic placeholder for now: check what it finds. Or mark each rally yourself with + Rally.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.edit.emptyHint")
        }
    }

    /// EditFinding: "Finding rallies · 38%", Pause, then + Rally / Split.
    private func findingPanel(_ s: RacketEditSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(findingLine).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("racket.edit.finding")
                    Spacer()
                    if scanID != nil {
                        Button(scanPaused ? "Resume" : "Pause") { pauseOrResumeScan() }
                            .font(.system(size: 15, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("racket.edit.pauseFind")
                    } else {
                        Button("OK") { scanFound = nil }
                            .font(.system(size: 15, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("racket.edit.findOK")
                    }
                }
                ProgressView(value: scanFraction).tint(SnappetColor.brand)
                Text("Found rallies appear dashed until you confirm them. Yours are never replaced.")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.hairline))
            HStack(spacing: 8) {
                primaryButton("+ Rally", id: "racket.edit.addRally") { startMark(s) }
                secondaryButton("Split", id: "racket.edit.split", enabled: s.splittable(at: position) != nil) {
                    mutate { _ = $0.split(at: position) }
                }
            }
        }
    }

    private var findingLine: String {
        if let n = scanFound, scanID == nil { return "Found \(n) \(n == 1 ? "rally" : "rallies")" }
        if scanPaused { return "Finding rallies · paused" }
        return "Finding rallies · \(Int((scanFraction * 100).rounded()))%"
    }

    /// EditMarking.
    private var markingPanel: some View {
        VStack(spacing: 12) {
            Button { endMark() } label: {
                Text("End rally here").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.onBrand)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(SnappetColor.brand, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("racket.edit.endRally")
            Button("Cancel this mark") { markStart = nil; problem = nil; playback.pause() }
                .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44)
                .accessibilityIdentifier("racket.edit.cancelMark")
            Text("The video keeps playing while you mark. You can also drag to the end and tap. Tags come next, or later.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// EditTrim: nudges on the handle last touched.
    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach([-1.0, -0.2, 0.2, 1.0], id: \.self) { d in
                    Button { if let e = edge, let r = current { nudge(e, r.id, d) } } label: {
                        Text(d < 0 ? "−\(trimNumber(-d)) s" : "+\(trimNumber(d)) s")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SnappetColor.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("racket.edit.nudge.\(d)")
                }
            }
            Text("The strip zooms in while you drag, and the handle clicks at each second. Rallies can’t overlap; a handle stops at its neighbour.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back to rally") { edge = nil }
                .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44)
                .accessibilityIdentifier("racket.edit.trimDone")
        }
    }

    private func trimNumber(_ d: Double) -> String { d == d.rounded() ? "\(Int(d))" : String(format: "%.1f", d) }

    // MARK: Inspector (EditSelected · EditSport)

    @ViewBuilder private func inspector(_ s: RacketEditSession, _ r: RacketRally) -> some View {
        let n = s.number(of: r.id) ?? 0
        let lines = RacketTagLines(ex: ex, ref: ref, rallies: s.visible)
        VStack(alignment: .leading, spacing: 10) {
            if sport.usesSets || doubles {
                let l = lines.scoreLine(r, sides: sides, winner: r.winner)
                HStack(alignment: .firstTextBaseline) {
                    Text((["Point \(n)"] + setLine(r, s, fallback: l.left)).joined(separator: " · "))
                        .font(.system(size: 14, weight: .semibold)).accessibilityIdentifier("racket.edit.title")
                    Spacer(minLength: 6)
                    if let right = doubles || !sport.usesSets ? l.right : nil {
                        Text(right).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                            .accessibilityIdentifier("racket.edit.serving")
                    }
                }
            } else {
                HStack {
                    Text("Rally \(n) · \(RacketPlayerText.clock(r.startSec - ref.startSec)) – \(RacketPlayerText.clock(r.endSec - ref.startSec)) · \(RacketPlayerText.seconds(r.durationSec))")
                        .font(.system(size: 14, weight: .semibold)).accessibilityIdentifier("racket.edit.title")
                    Spacer()
                    if r.winner != nil {
                        Text(RacketPlayerCopy.result(r, sides: sides)).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(r.winner == .us ? SnappetColor.brand : SnappetColor.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(r.winner == .us ? SnappetColor.brand : SnappetColor.hairline))
                    }
                }
            }
            if r.isGuess {
                Text("Found by Find rallies. Tag it to confirm it.").font(SnappetType.detail)
                    .foregroundStyle(SnappetColor.perfModerate).accessibilityIdentifier("racket.edit.suggested")
            }
            HStack(spacing: 8) {
                RacketTagChip(label: sides.us, selected: r.winner == .us, id: "racket.edit.winner.us", wide: true) {
                    mutate { $0.toggleWinner(r.id, .us) }
                }
                RacketTagChip(label: sides.them, selected: r.winner == .them, id: "racket.edit.winner.them", wide: true) {
                    mutate { $0.toggleWinner(r.id, .them) }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RacketRallyEnding.choices(for: sport), id: \.self) { e in
                        RacketTagChip(label: e.label, selected: r.ending == e, id: "racket.edit.end.\(e.rawValue)") {
                            mutate { $0.toggleEnding(r.id, e) }
                        }
                    }
                }
            }
            if doubles {
                Text("Last shot. Optional").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(players, id: \.self) { p in
                            RacketTagChip(label: p, selected: r.lastShotBy == p, id: "racket.edit.last.\(p)") {
                                mutate { $0.setLastShot(r.id, r.lastShotBy == p ? nil : p) }
                            }
                        }
                        RacketTagChip(label: "Skip", selected: r.lastShotBy == nil, id: "racket.edit.last.skip") {
                            mutate { $0.setLastShot(r.id, nil) }
                        }
                    }
                }
            }
            // EditSport: the sport's links right under its rows; the rally actions follow.
            if sport.usesSets || doubles { linksRow }
            HStack(spacing: 8) {
                secondaryButton("Shots", id: "racket.edit.shots") { shotsOpen = true; playback.seek(to: r.startSec) }
                secondaryButton("Merge next", id: "racket.edit.merge", enabled: s.next(after: r.id) != nil) {
                    mutate { _ = $0.mergeNext(r.id) }
                }
                Button { mutate { $0.notRally(r.id) }; selected = nil } label: {
                    Text("Not a rally").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.perfHard.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.edit.notRally")
            }
            if !(sport.usesSets || doubles) { linksRow }
        }
    }

    private var linksRow: some View {
        HStack {
            if let d = RacketTagDetail.link(for: sport) {
                Button(d.linkTitle) { detail = d }.accessibilityIdentifier("racket.edit.detail.\(d.rawValue)")
            }
            Spacer()
            Button("What counts as a rally?") { rules = true }.accessibilityIdentifier("racket.edit.rules")
        }
        .font(.system(size: 15, weight: .semibold))
        .frame(minHeight: 44)
    }

    /// EditSport "Point 12 · Games 4–3 · 40–30": the set and the point before this rally, from your tags.
    private func setLine(_ r: RacketRally, _ s: RacketEditSession, fallback: String?) -> [String] {
        guard sport.usesSets, let i = ref.setIndex, let rules = ex?.racketLiveRules(unitIndex: i) else {
            return [fallback].compactMap { $0 }
        }
        let l = RacketTagSportLine.sets(rules: rules, points: RacketTagScore.points(before: r.id, in: s.visible))
        return [l.games, l.point.hasPrefix("Point ") ? String(l.point.dropFirst(6)) : l.point]
    }

    private var players: [String] {
        var names = ["You"]
        if let p = ex?.partner, !p.isEmpty { names.append(p) }
        return names + RacketOpponentTeam.players(player1: ex?.racketOpponentPlayer1, player2: ex?.racketOpponentPlayer2,
                                                  team: ex?.opponent)
    }

    // MARK: Shots (EditShots)

    @ViewBuilder private func shotsPanel(_ r: RacketRally) -> some View {
        let shots = r.shots ?? []
        VStack(alignment: .leading, spacing: 8) {
            if shots.isEmpty {
                Text("Add each shot as you watch: who hit it, forehand or backhand, and the shot.")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(shots.enumerated()), id: \.element.id) { k, shot in
                HStack(spacing: 8) {
                    Text("\(k + 1)").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                        .frame(width: 18, alignment: .leading)
                    Button { setShots(r, RacketShotTagging.swapSide(shots, id: shot.id)) } label: {
                        chip(shot.side == .us ? sides.us : sides.them, dashed: false, width: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("racket.edit.shot.side.\(k)")
                    if doubles {
                        Menu {
                            Button("Not named") { setShots(r, RacketShotTagging.setPlayer(shots, id: shot.id, player: nil)) }
                            ForEach(RacketShotTagging.players(side: shot.side, partner: ex?.partner,
                                                              opponents: RacketOpponentTeam.players(player1: ex?.racketOpponentPlayer1,
                                                                                                   player2: ex?.racketOpponentPlayer2,
                                                                                                   team: ex?.opponent)), id: \.self) { n in
                                Button(n) { setShots(r, RacketShotTagging.setPlayer(shots, id: shot.id, player: n)) }
                            }
                        } label: { chip(shot.player ?? "Player?", dashed: shot.player == nil, width: 64) }
                        .accessibilityIdentifier("racket.edit.shot.player.\(k)")
                    } else {
                        Button { setShots(r, RacketShotTagging.toggleHand(shots, id: shot.id)) } label: {
                            chip(shot.handLabel, dashed: false, width: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("racket.edit.shot.hand.\(k)")
                    }
                    Menu {
                        ForEach(RacketShotType.choices(for: sport), id: \.self) { t in
                            Button(t) { setShots(r, RacketShotTagging.setType(shots, id: shot.id, type: t)) }
                        }
                        Divider()
                        Button("Remove this shot", role: .destructive) { setShots(r, RacketShotTagging.remove(shots, id: shot.id)) }
                    } label: { chip(shot.type ?? "Choose", dashed: shot.type == nil, width: nil) }
                    .accessibilityIdentifier("racket.edit.shot.type.\(k)")
                }
            }
            HStack {
                Button { setShots(r, RacketShotTagging.adding(to: shots, at: position)); Haptics.tap() } label: {
                    Text("+ Shot at playhead").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.edit.addShot")
                Spacer()
                Button("Back to rally") { shotsOpen = false }
                    .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44)
                    .accessibilityIdentifier("racket.edit.backToRally")
            }
        }
    }

    private func setShots(_ r: RacketRally, _ shots: [RacketShot]) { mutate { $0.setShots(r.id, shots) } }

    private func chip(_ text: String, dashed: Bool, width: CGFloat?) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(dashed ? SnappetColor.textSecondary : SnappetColor.ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width).frame(maxWidth: width == nil ? .infinity : nil, minHeight: 44)
            .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(SnappetColor.hairline, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : [])))
    }

    // MARK: Rally list (EditList)

    private func listView(_ s: RacketEditSession) -> some View {
        let rows = RacketEditList.rows(s.visible, filter: filter, partStart: ref.startSec, sides: sides)
        let here = selected ?? s.rally(at: position)?.id ?? RacketPlayerRallies(s.visible).lastStarted(at: position).map { s.visible[$0].id }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RacketEditListFilter.allCases, id: \.self) { f in
                        RacketTagChip(label: f.chip(s.visible), selected: filter == f, id: "racket.edit.filter.\(f.rawValue)") {
                            filter = f
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 12)
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { jump(to: row.id) } label: {
                            HStack(spacing: 10) {
                                Text("Rally \(row.number)").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                Text(row.detail).font(.system(size: 13).monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                                Spacer()
                                Text(row.result).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(row.untagged ? SnappetColor.perfModerate
                                                     : row.result.hasPrefix(sides.us) ? SnappetColor.brand : SnappetColor.textSecondary)
                            }
                            .padding(.horizontal, 10).frame(minHeight: 46)
                            .background(row.id == selected || (selected == nil && s.rally(at: position)?.id == row.id)
                                        ? SnappetColor.brand.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                        .accessibilityIdentifier("racket.edit.row.\(row.number)")
                        Divider().overlay(SnappetColor.hairline)
                    }
                }
                HStack {
                    Button("Next untagged") {
                        if let r = RacketEditList.nextUntagged(s.visible, after: position) { jump(to: r.id) }
                    }
                    .disabled(!s.visible.contains { !$0.isTagged })
                    .accessibilityIdentifier("racket.edit.nextUntagged")
                    Spacer()
                    Button("Back to the strip") { listOpen = false }.accessibilityIdentifier("racket.edit.backToStrip")
                }
                .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44)
                // Kept from the Watch player's temporary Edit list (prompt 253): the analysis view and other apps'
                // suggestions. They open outside Edit, so they wait for Done or Cancel.
                if onAnalysis != nil || compare != nil {
                    Divider().overlay(SnappetColor.hairline)
                    HStack {
                        if let onAnalysis {
                            Button("Analysis view") { close(then: onAnalysis) }.accessibilityIdentifier("racket.edit.analysis")
                        }
                        Spacer()
                        if let compare {
                            Button(compare.label) { close(then: compare.action) }.accessibilityIdentifier("racket.edit.compare")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold)).frame(minHeight: 44)
                    .disabled(s.hasChanges)
                    if s.hasChanges {
                        Text("Done or Cancel your edits first.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12)
        }
        // EditList opens on the rally at the playhead (Rally 11 – 15 around 12 on the board).
        .onAppear { if let here { proxy.scrollTo(here, anchor: .center) } }
        }
    }

    private func jump(to id: UUID) {
        guard let r = session?.rally(id) else { return }
        playback.pause()
        playback.seek(to: r.startSec)
        selected = id
        edge = nil
        shotsOpen = false
        listOpen = false
    }

    // MARK: Looks tab (EditLooks)

    private func looksTab(_ s: RacketEditSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(RacketLook.allCases, id: \.self) { l in
                    Button {
                        mutate { $0.setLook(l) }
                        playback.look = l
                        Haptics.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let img = lookThumbs[l] {
                                    Image(uiImage: img).resizable().scaledToFill()
                                } else {
                                    Color(white: 0.18)
                                }
                            }
                            .frame(maxWidth: .infinity).frame(height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(s.state.look == l ? SnappetColor.ink : SnappetColor.hairline, lineWidth: s.state.look == l ? 2 : 1))
                            Text(l.label).font(.system(size: 13, weight: s.state.look == l ? .semibold : .regular))
                                .foregroundStyle(s.state.look == l ? SnappetColor.brand : SnappetColor.ink)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l.label)
                    .accessibilityAddTraits(s.state.look == l ? .isSelected : [])
                    .accessibilityIdentifier("racket.edit.look.\(l.rawValue)")
                }
            }
            Text("Use for").font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
            HStack(spacing: 8) {
                ForEach(RacketLookScope.allCases, id: \.self) { sc in
                    RacketTagChip(label: sc.label, selected: s.state.lookScope == sc, id: "racket.edit.scope.\(sc.rawValue)", wide: true) {
                        mutate { $0.setLookScope(sc) }
                    }
                }
            }
            Text("A look changes playback and sharing only. The video in Photos stays as filmed, and rally finding reads the original.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.edit.lookNote")
        }
        .padding(.horizontal, 14).padding(.top, 14)
        .task { await makeLookThumbs() }
    }

    private func makeLookThumbs() async {
        guard lookThumbs.isEmpty else { return }
        // The player draws with the current look: the presets start from the original frame.
        guard let base = await originalStill() ?? playback.poster else { return }
        var out: [RacketLook: UIImage] = [:]
        for l in RacketLook.allCases { out[l] = RacketLookRenderer.still(base, look: l) }
        lookThumbs = out
    }

    /// A frame without the look (the strip's generator draws with the player's composition).
    private func originalStill() async -> UIImage? {
        guard let player = playback.player else { return nil }
        let was = playback.showOriginal
        playback.showOriginal = true
        defer { playback.showOriginal = was }
        return await RacketVideoLibrary.shared.thumbnails(player, times: [max(0, position - ref.startSec)], maxSide: 240).first ?? nil
    }

    // MARK: Score tab (EditScore)

    @ViewBuilder private func scoreTab(_ s: RacketEditSession) -> some View {
        if let ex, ex.isRacketMatch {
            let format = ex.racketFormat
            let unit = format.sport.unit
            // Every game with a video part, and every logged game (EditScore "Game 1 · unconfirmed · Game 2 · no score").
            let parts = RacketVideoRows.rows(for: ex).compactMap(\.setIndex).max().map { $0 + 1 } ?? 0
            let count = max(ex.sets.count, (ref.setIndex ?? 0) + 1, parts)
            let score = shownScore(ex, s, index: scoreIndex)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0..<count, id: \.self) { i in
                                RacketTagChip(label: RacketEditScoreCopy.chip(s.state.scores[i] != nil ? .confirmed(s.state.scores[i]!)
                                                                                  : (i < ex.sets.count ? ex.sets[i].racketScoreState : nil),
                                                                              unit: unit, index: i),
                                              selected: scoreIndex == i, id: "racket.edit.game.\(i)") { scoreIndex = i }
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        scoreColumn(sides.us, value: score.scoreFor, id: "mine") { v in setScore(ex, s, mine: v) }
                        scoreColumn(sides.them, value: score.scoreAgainst, id: "theirs") { v in setScore(ex, s, theirs: v) }
                    }
                    if let w = RacketScoreEntry.warning(score, format: format) {
                        Text(w).font(SnappetType.detail.weight(.semibold)).foregroundStyle(SnappetColor.perfModerate)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.edit.score.warning")
                    }
                    if scoreIndex == ref.setIndex {
                        Text(RacketEditScoreCopy.fromTags(s.visible, sides: sides))
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.edit.score.fromTags")
                    } else {
                        Text("Done marks the score confirmed.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                .padding(14)
            }
        } else {
            Text("A drill has no score.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("racket.edit.score.none")
        }
    }

    private func shownScore(_ ex: SessionExercise, _ s: RacketEditSession, index: Int) -> RacketUnitScore {
        if let e = s.state.scores[index] { return e }
        if index < ex.sets.count, let sc = ex.sets[index].racketScore { return sc }
        let f = ex.racketFormat
        let initial = RacketScoring.initialScore(format: f, superTiebreak: f.isSuperTiebreak(index: index))
        return RacketUnitScore(scoreFor: initial.0, scoreAgainst: initial.1, superTiebreak: f.isSuperTiebreak(index: index))
    }

    private func setScore(_ ex: SessionExercise, _ s: RacketEditSession, mine: Int? = nil, theirs: Int? = nil) {
        var sc = shownScore(ex, s, index: scoreIndex)
        if let mine { sc.scoreFor = max(0, mine) }
        if let theirs { sc.scoreAgainst = max(0, theirs) }
        let i = scoreIndex
        mutate { $0.setScore(i, sc) }
        Haptics.tap()
    }

    private func scoreColumn(_ who: String, value: Int, id: String, set: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 6) {
            Text(who).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
            Text("\(value)").font(.system(size: 44, weight: .light)).monospacedDigit()
                .accessibilityIdentifier("racket.edit.score.\(id)")
            HStack(spacing: 8) {
                stepper("−", id: "\(id).minus") { set(value - 1) }
                stepper("+", id: "\(id).plus") { set(value + 1) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepper(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 20, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SnappetColor.hairline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.edit.score.\(id)")
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    tab = t
                    listOpen = false
                    playback.showOriginal = false
                } label: {
                    VStack(spacing: 0) {
                        Rectangle().fill(tab == t ? SnappetColor.brand : Color.clear).frame(height: 2)
                        Text(t.label).font(.system(size: 15, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? SnappetColor.brand : SnappetColor.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
                .accessibilityIdentifier("racket.edit.tab.\(t.rawValue)")
            }
        }
        .background(Color.black)
        .overlay(alignment: .top) { Rectangle().fill(SnappetColor.hairline).frame(height: 0.5) }
    }

    // MARK: EditDiscard

    private func discardSheet(_ s: RacketEditSession) -> some View {
        VStack(spacing: 10) {
            Text(s.discardLine).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.edit.discardLine")
            Button { askDiscard = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { discard() } } label: {
                Text("Discard changes").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.perfHard.opacity(0.6)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("racket.edit.discard")
            Button { askDiscard = false } label: {
                Text("Keep editing").font(.system(size: 17, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SnappetColor.hairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("racket.edit.keepEditing")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.07).ignoresSafeArea())
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: Detail sheets (TnServe · PdWall · SqLet), on the working copy

    @ViewBuilder private func detailSheet(_ d: RacketTagDetail, rally r: RacketRally) -> some View {
        let rs = session?.visible ?? []
        let number = (rs.firstIndex { $0.id == r.id } ?? 0) + 1
        let lines = RacketTagLines(ex: ex, ref: ref, rallies: rs)
        let video = RacketRallyVideo(log: log, partStart: ref.startSec, partEnd: ref.endSec, range: r.startSec...r.endSec,
                                     sport: sport, maxHeight: 280, onTurn: { t in
                                         // Rotate (prompt 257): the recording's turn, and the player under Edit at once.
                                         playback.quarterTurns = t
                                         store.updateLog(ref.exerciseID) { $0.quarterTurns = RacketVideoTurn.stored(t) }
                                     })
        switch d {
        case .serve:
            let rules = ref.setIndex.flatMap { ex?.racketLiveRules(unitIndex: $0) }
            let t = rules.map { RacketLiveScore(rules: $0, points: RacketTagScore.points(before: r.id, in: rs)).tally }
            let server = rules.flatMap { _ in lines.serverSide(r) }
            RacketServeSheet(number: number, video: video, gameLine: t.map { "Game \($0.gamesFor)–\($0.gamesAgainst)" },
                             servingLine: lines.servingWho(r, sides: sides), sides: sides, serve: r.serve, winner: r.winner,
                             server: server,
                             onNextPoint: { o, w in
                                 let implied = o.map { RacketServeOutcome.implied($0, server: server) }
                                 var winner = w ?? implied?.winner
                                 if o == .letReplay { winner = nil }
                                 mutate { $0.setTags(r.id, winner: winner, ending: implied?.ending ?? r.ending, lastShotBy: r.lastShotBy,
                                                     serve: .some(o)) }
                                 detail = nil
                             },
                             onSkip: { detail = nil }, onClose: { detail = nil })
        case .wall:
            RacketChoiceDetailSheet(title: "Rally \(number)", video: video, question: "Did the ball bounce first?",
                                    options: RacketWallBounce.allCases.map { ($0.rawValue, $0.title, $0.subtitle) },
                                    selected: r.wall?.rawValue, footnote: nil, idPrefix: "racket.wall",
                                    onNext: { raw in
                                        if let w = raw.flatMap(RacketWallBounce.init(rawValue:)) {
                                            mutate { $0.setTags(r.id, winner: r.winner, ending: RacketWallBounce.ending(w, current: r.ending),
                                                                lastShotBy: r.lastShotBy, wall: .some(w)) }
                                        }
                                        detail = nil
                                    },
                                    onSkip: { detail = nil }, onClose: { detail = nil })
        case .letCall:
            RacketChoiceDetailSheet(title: "Rally \(number)", video: video, question: "Was there interference?",
                                    options: RacketLetCall.allCases.map { ($0.rawValue, $0.title, $0.subtitle) },
                                    selected: RacketLetCall(ending: r.ending)?.rawValue, footnote: RacketLetCall.footnote,
                                    idPrefix: "racket.let",
                                    onNext: { raw in
                                        if let c = raw.flatMap(RacketLetCall.init(rawValue:)) {
                                            mutate { $0.setTags(r.id, winner: c == .letReplay ? nil : r.winner, ending: c.ending,
                                                                lastShotBy: r.lastShotBy) }
                                        }
                                        detail = nil
                                    },
                                    onSkip: { detail = nil }, onClose: { detail = nil })
        }
    }

    // MARK: Actions

    private func startMark(_ s: RacketEditSession) {
        problem = nil
        if let p = RacketEditMark.canStart(at: position, rallies: s.visible) {
            problem = p.message
            Haptics.warning()
            return
        }
        selected = nil
        edge = nil
        markStart = position
        if !playback.playing { playback.play() }
        Haptics.tap()
    }

    private func endMark() {
        guard let start = markStart, let s = session else { return }
        switch RacketEditMark.finish(start: start, end: position, rallies: s.visible, lo: ref.startSec, hi: ref.endSec) {
        case .success(let m):
            var id: UUID?
            mutate { id = $0.add(m.range) }
            markStart = nil
            playback.pause()
            playback.seek(to: m.range.lowerBound)
            selected = id
            problem = m.clamped ? "It stopped where the next rally starts: rallies can’t overlap." : nil
            Haptics.success()
        case .failure(let p):
            problem = p.message
            Haptics.warning()
        }
    }

    private var model: RallyModelInfo? { RacketCapabilityRegistry.capabilities(for: sport).model }

    private var scanFraction: Double {
        guard let id = scanID else { return scanFound != nil ? 1 : 0 }
        if let live = RacketScanCenter.shared.live[id] { return live }
        return log?.allScans.first { $0.id == id }?.fraction ?? 0
    }

    private func findRallies() {
        guard let model else { return }
        playback.pause()
        selected = nil
        scanFound = nil
        scanPaused = false
        scanID = RacketScanCenter.shared.enqueue([ref], model: model, store: store).first
        scanTouchedStore = true
    }

    private func pauseOrResumeScan() {
        guard let id = scanID else { return }
        if scanPaused {
            RacketScanCenter.shared.resume(id, exerciseID: ref.exerciseID, store: store)
            scanPaused = false
        } else {
            RacketScanCenter.shared.stop(id)
            scanPaused = true
        }
    }

    /// Follow the scan; when it's done, its guesses join the working copy (dashed, never over yours).
    private func watchScan() async {
        guard let id = scanID else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            guard let rec = store.ex(ref.exerciseID)?.racketRecordingLog?.allScans.first(where: { $0.id == id }) else { continue }
            if rec.status == .done {
                let found = RacketRallyMarking.inRange(store.ex(ref.exerciseID)?.racketRecordingLog?.allRallies ?? [],
                                                       ref.startSec, ref.endSec).filter(\.isGuess)
                var n = 0
                mutate { n = $0.mergeFound(found) }
                scanFound = n
                scanID = nil
                return
            }
            if rec.status == .failed {
                problem = rec.note ?? "Find rallies stopped."
                scanID = nil
                return
            }
        }
    }

    private func cancel() {
        guard let s = session else { onClose(); return }
        if s.hasChanges { askDiscard = true } else { discard() }
    }

    private func discard() {
        if let id = scanID { RacketScanCenter.shared.stop(id) }
        // A scan that finished while editing put its guesses on the session: put the part back as it was.
        if scanTouchedStore {
            let part = originalPart
            let lo = ref.startSec, hi = ref.endSec
            store.updateLog(ref.exerciseID) { l in
                let outside = l.allRallies.filter { !($0.startSec >= lo - 0.01 && $0.startSec < hi) }
                l.rallies = (outside + part).sorted { $0.startSec < $1.startSec }
            }
        }
        if let s = session { playback.look = s.original.look }
        playback.showOriginal = false
        askDiscard = false
        onClose()
    }

    private func done() {
        guard let s = session else { onClose(); return }
        let lo = ref.startSec, hi = ref.endSec
        if s.changedRallies > 0 || s.lookChanged || scanTouchedStore {
            store.updateLog(ref.exerciseID) { l in
                let outside = l.allRallies.filter { !($0.startSec >= lo - 0.01 && $0.startSec < hi) }
                l.rallies = (outside + s.rallies).sorted { $0.startSec < $1.startSec }
                if s.lookChanged { RacketLookStore.apply(s.state.look, scope: s.state.lookScope, partStart: lo, to: &l) }
            }
        }
        if s.lookChanged && s.state.lookScope == .always {
            UserDefaults.standard.set(s.state.look.rawValue, forKey: RacketLookStore.alwaysKey)
        }
        for (i, score) in s.state.scores where s.state.scores[i] != s.original.scores[i] {
            var set = SetLog(durationSec: nil)
            set.scoreFor = score.scoreFor
            set.scoreAgainst = score.scoreAgainst
            set.tiebreakFor = score.tiebreakFor
            set.tiebreakAgainst = score.tiebreakAgainst
            if score.superTiebreak { set.superTiebreak = true }
            store.saveScore(ref.exerciseID, unit: i, set)
        }
        playback.look = s.state.look
        playback.showOriginal = false
        if s.hasChanges { Haptics.success() }
        onClose()
    }

    private func close(then action: @escaping () -> Void) {
        discard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { action() }
    }

    // MARK: Small pieces

    private func pill(_ text: String, bold: Bool = false) -> some View {
        Text(text).font(.system(size: 13, weight: bold ? .bold : .semibold)).foregroundStyle(SnappetColor.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private func primaryButton(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.onBrand)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(SnappetColor.brand, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func secondaryButton(_ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.hairline))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }
}

/// Edit's trim colour: the yellow of Photos' trim handles (EditSelected / EditTrim). Meaning, not decoration: "this
/// rally is being trimmed".
enum RacketEditColor {
    static let trim = Color(red: 0.96, green: 0.74, blue: 0.24)
}
