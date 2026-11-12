import SwiftUI

// MARK: - Game-by-game match screens (prompt 249, issue #438 parity)
//
// One full-screen cover for a match filmed game by game, and for a match scored without video:
// Camera check (NoModelCamera) → Warmup → the game screen (DimOff · CameraViewOff · StatsOff, Warm, BdInterval,
// TnTiebreak) → Score (SaveGame) → Break (GameBreak) → Countdown (GameCountdown) → … → match over; ScoreOnly; and
// the Interrupted / InterruptedStop / Still playing? panels shared with the record-everything screen. Thin renderers
// over the pure `RacketGameFlow` (`RacketMatchFlow.swift`) and `RacketRecordingMachine` (`recording: .byUnit`); the
// camera and Photos stay in `Services/RacketRecorder.swift`.

/// What the host presents: a match's camera check (then warmup → game screen), or scoring without video.
struct RacketGameCoverTarget: Identifiable {
    enum Start: Equatable { case camera, scoreOnly }
    let id = UUID()
    let exerciseID: UUID
    let start: Start
}

struct RacketGameCover: View {
    /// The match, live from the host (its games update as they're logged).
    let ex: SessionExercise
    let start: RacketGameCoverTarget.Start
    let defaults: RacketRecordingDefaults
    /// The latest heart rate from the Watch / a strap (StatsOff "Heart rate"); nil ⇒ "–".
    var heartRate: Double? = nil
    /// Warmup's "How to record this match" changed it.
    let onRecordingMode: (RacketRecordingMode) -> Void
    /// "Who serves first?" (nil ⇒ Skip).
    let onFirstServer: (RacketServe.Side?) -> Void
    /// Save a game: the log and its set index (a new game appends; an index below the count rewrites it).
    let onUnit: (SetLog, Int) -> Void
    /// A Photos part was saved, with the game it belongs to (nil between games).
    let onPartSaved: (RecordedClip, Int?) -> Void
    /// The recording log changed: persist it on the match.
    let onLog: (RacketRecordingLog) -> Void
    /// Warmup chose "Everything, split later" and the storage check passed: record everything instead.
    let onRecordEverything: (RacketRecordingQuality) -> Void
    /// Match over: close; `true` ⇒ there's video to find rallies in (Score → Analyzing, via Your videos).
    let onMatchOver: (Bool) -> Void
    let onClose: () -> Void

    private enum Stage: Equatable { case camera, warmup, game }

    @State private var stage: Stage = .camera
    @State private var recorder = RacketRecorder()
    @State private var machine: RacketRecordingMachine?
    @State private var flow = RacketGameFlow(filming: true, unitIndex: 0, options: .init(sport: .tableTennis, pointsTo: 11))
    @State private var score = RacketLiveScore(rules: .init(kind: .rally, pointsTo: 11))
    /// The tally has Watch points in it (the score sheet says "Filled in from your Watch").
    @State private var scoreFromWatch = false
    @State private var now = Date()
    @State private var show: RacketRecordingShow = .dim
    @State private var thermal: RacketThermalLevel = .ok
    @State private var firstServer: RacketServe.Side?
    @State private var choice: RacketRecordingMode = .byUnit
    @State private var scoring = false
    @State private var storageCheck = false
    @State private var accessDenied = false
    @State private var configured = false
    @State private var idleTimerWas = false
    @State private var watchToken: UUID?
    /// "11–9", the game just saved (the break's Watch header).
    @State private var lastUnitLabel: String?
    /// Whether this match's log may be written (an earlier record-everything log on it is never overwritten).
    @State private var writesLog = true

    private var sport: RacketSport { ex.racketSport ?? ex.racketFormat.sport }
    private var unit: RacketUnit { sport.unit }
    private var sides: (us: String, them: String) { RacketWatchCopy.sides(opponent: ex.opponent, doubles: ex.isDoubles) }
    private var unitTitle: String { RacketGameCopy.unitTitle(unit, index: flow.unitIndex) }

    var body: some View {
        ZStack {
            switch stage {
            case .camera: cameraCheck
            case .warmup: warmup
            case .game: game
            }
        }
        // One preview for the cover's life (device feedback round 2: attaching one mid-recording stopped the recording).
        .racketPersistentPreview(session: recorder.session, fake: recorder.fake)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { recorder.screenAppeared(); setUp() }
        .onDisappear(perform: tearDown)
        .onChange(of: watchState) { _, s in if let s { RacketWatchRelay.shared.publish(s) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
                tick()
            }
        }
        .sheet(isPresented: $scoring) {
            RacketSaveGameSheet(ex: ex, unitIndex: flow.unitIndex, live: score, fromWatch: scoreFromWatch,
                                filming: flow.filming, options: $flow.options,
                                durationSec: flow.gameStartedAt.map { Date().timeIntervalSince($0) },
                                onSave: { log, startBreak in saveGame(log, startBreak: startBreak) },
                                onCancel: { flow.cancelScore() })
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $storageCheck) {
            RacketStorageSheet(mode: .match, defaultQuality: defaults.quality, cancelLabel: "Back") { quality in
                onRecordingMode(.everything)
                onRecordEverything(quality)
            }
            .presentationDetents([.large])
        }
    }

    // MARK: Set-up

    private func setUp() {
        RacketRecorder.trace("game cover setUp configured=\(configured)")
        guard !configured else { return }
        configured = true
        idleTimerWas = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        firstServer = ex.racketFirstServerRaw.flatMap(RacketServe.Side.init(rawValue:))
        choice = ex.racketRecording == .everything ? .everything : .byUnit
        show = .initialGame
        writesLog = ex.racketRecordingLog.map(\.isGameByGame) ?? true
        let filming = start == .camera
        flow = RacketGameFlow(filming: filming, unitIndex: ex.sets.count,
                              options: .init(sport: sport, pointsTo: ex.racketFormat.pointsTo),
                              startInWarmup: filming)
        score = RacketLiveScore(rules: RacketLiveRules(format: ex.racketFormat, unitIndex: ex.sets.count))
        if filming {
            stage = .camera
            openCamera()
        } else {
            stage = .game
            flow.startGame(now: Date())
        }
        watchToken = RacketWatchRelay.shared.attach(ex.id) { command, at in handleWatch(command, now: at) }
        if let s = watchState { RacketWatchRelay.shared.publish(s) }
    }

    private func openCamera() {
        recorder.onThermal = { level in thermal = level }
        thermal = recorder.thermal
        recorder.onPartSaved = { clip in
            guard var m = machine else { onPartSaved(clip, nil); return }
            let index = m.log.flatMap { l in l.gameIndex(at: l.offset(clip.capturedAt)) }
            onPartSaved(clip, index)
            m.assetSaved(localIdentifier: clip.localIdentifier, startedAt: clip.capturedAt, durationSec: clip.durationSec)
            machine = m
            persistLog()
        }
        recorder.onInterrupted = { reason in
            guard var m = machine else { return }
            m.interrupt(reason, now: Date())
            machine = m
            persistLog()
            Haptics.warning()
        }
        Task {
            let ok = await RacketRecorder.requestAccess()
            RacketRecorder.trace("camera check access ok=\(ok)")
            accessDenied = !ok
            if ok { recorder.startPreview(quality: defaults.quality) }
        }
    }

    private func tearDown() {
        let was = idleTimerWas, id = ex.id, token = watchToken
        recorder.screenDisappeared {
            UIApplication.shared.isIdleTimerDisabled = was
            if let token { RacketWatchRelay.shared.detach(id, token: token) }
        }
    }

    // MARK: Flow plumbing

    /// Run one flow event, then reconcile the machine: game marks, interval marks, capture.
    private func step(_ event: (inout RacketGameFlow) -> [RacketGameFlow.Effect]) {
        let before = flow.phase
        let effects = event(&flow)
        let at = Date()
        if var m = machine, !m.isEnded {
            var machineEffects: [RacketRecordingMachine.Effect] = []
            for e in effects {
                switch e {
                case .resumeCapture: machineEffects += m.resumeCapture(now: at)
                case .pauseCapture: machineEffects += m.pauseCapture(now: at)
                case .openScore, .matchOver: break
                }
            }
            let wasGame = before == .playing || isInterval(before) || isScoring(before)
            let isGame = flow.phase == .playing || isInterval(flow.phase) || isScoring(flow.phase)
            if !wasGame && isGame { m.openGame(index: flow.unitIndex, now: at) }
            if wasGame && !isGame { m.closeGame(now: at) }
            if !isInterval(before) && isInterval(flow.phase) { m.openInterval(now: at) }
            if isInterval(before) && !isInterval(flow.phase) { m.closeInterval(now: at) }
            if effects.contains(.matchOver) { machineEffects += m.end(now: at) }
            machine = m
            perform(machineEffects)
            persistLog()
        }
        for e in effects {
            switch e {
            case .openScore: scoring = true
            case .matchOver:
                Haptics.success()
                let hasVideo = (machine?.log?.recordedSec(now: at) ?? 0) > 0 && writesLog
                onMatchOver(hasVideo)
            case .resumeCapture, .pauseCapture: break
            }
        }
    }

    private func isInterval(_ p: RacketGameFlow.Phase) -> Bool {
        switch p { case .interval, .intervalPaused: return true; default: return false }
    }
    private func isScoring(_ p: RacketGameFlow.Phase) -> Bool { if case .scoring = p { return true } else { return false } }
    private func isPlaying(_ p: RacketGameFlow.Phase) -> Bool { p == .playing || isInterval(p) || isScoring(p) }

    private func perform(_ effects: [RacketRecordingMachine.Effect]) {
        for e in effects {
            switch e {
            case .startCapture: recorder.startCapture()
            case .stopCapture: recorder.stopCapture()
            case .askStillPlaying: Haptics.warning()
            case .ended(let route):
                // Still playing? timed out, or End from an interruption: confirm the game, then match over.
                if route == .score, flow.phase == .playing || isInterval(flow.phase) {
                    _ = flow.endGame(matchOver: true, now: Date())
                    scoring = true
                }
            case .logBlock, .continueWithoutVideo: break
            }
        }
    }

    private func machineAct(_ event: (inout RacketRecordingMachine) -> [RacketRecordingMachine.Effect]) {
        guard var m = machine else { return }
        let effects = event(&m)
        machine = m
        perform(effects)
        persistLog()
    }

    private func persistLog() {
        guard writesLog, var log = machine?.log else { return }
        log.split = RacketGameByGameSplit.split(log, now: log.endedAt ?? Date()) ?? log.split
        onLog(log)
    }

    private func tick() {
        step { $0.tick(now: now) }
        machineAct { $0.tick(now: now) }
        if let m = machine, m.interruption == nil, !m.isEnded { recorder.ensureCapturing(m.capturing) }
        // After a resumed interruption the flow says whether a break / interval is recording.
        if let m = machine, !m.isEnded, m.interruption == nil, m.capturing != flow.wantsCapture, m.phase == .recordingMatch {
            machineAct { flow.wantsCapture ? $0.resumeCapture(now: Date()) : $0.pauseCapture(now: Date()) }
        }
    }

    // MARK: Actions

    /// Warmup "Start recording" / the Watch's Start.
    private func startRecording() {
        if choice == .everything {
            storageCheck = true
            return
        }
        onRecordingMode(.byUnit)
        onFirstServer(firstServer)
        var m = RacketRecordingMachine(kind: .match, recording: .byUnit,
                                       stillPlayingMinutes: defaults.stillPlayingMinutes(for: .byUnit), now: Date())
        m.baseSetIndex = ex.sets.count
        m.quality = defaults.quality
        if let old = ex.racketRecordingLog, old.isGameByGame { m.continueLog(old) }
        let effects = m.start(now: Date())
        machine = m
        perform(effects)
        stage = .game
        step { $0.startGame(now: Date()) }
        Haptics.tap()
    }

    private func point(us: Bool, fromWatch: Bool) {
        guard flow.phase == .playing || isInterval(flow.phase) else { return }
        let first = score.isEmpty
        guard score.point(us ? .us : .them) else { return }
        if fromWatch { scoreFromWatch = true }
        machineAct { m in
            m.noteActivity(now: Date())
            if first { m.mark(.firstPoint, now: Date()) }
            m.markPoint(us: us, now: Date())
            return []
        }
        let s = score
        step { $0.pointsChanged(s, now: Date()) }
        Haptics.tap()
    }

    private func undo() {
        guard flow.phase == .playing, score.undo() else { return }
        machineAct { $0.dropLastPoint(); return [] }
    }

    private func mark() {
        machineAct { $0.mark(.moment, now: Date()); return [] }
        Haptics.tap()
    }

    private func saveGame(_ log: SetLog, startBreak: Bool) {
        let index = flow.unitIndex
        onUnit(log, index)
        lastUnitLabel = log.racketScore.map(\.label)
        var units = ex.sets.map(\.racketScore)
        if index < units.count { units[index] = log.racketScore } else { units.append(log.racketScore) }
        let decided = RacketScoring.state(units: units.compactMap { $0 }, format: ex.racketFormat, end: ex.racketEnd).isDecided
        step { $0.saved(startBreak: startBreak, decided: decided, now: Date()) }
        if !flow.isEnded { resetScoreForNext() }
    }

    private func resetScoreForNext() {
        score = RacketLiveScore(rules: RacketLiveRules(format: ex.racketFormat, unitIndex: flow.unitIndex))
        scoreFromWatch = false
    }

    /// InterruptedStop "Keep scoring without video" → ScoreOnly with the same game and tally.
    private func keepScoringWithoutVideo() {
        machineAct { $0.continueWithoutVideo(now: Date()) }
        recorder.stopPreview()
        let kept = score
        var f = RacketGameFlow(filming: false, unitIndex: flow.unitIndex, options: flow.options, startInWarmup: false)
        f.startGame(now: flow.gameStartedAt ?? Date())
        flow = f
        score = kept
    }

    /// ScoreOnly "Start recording instead" → the camera check, then warmup; the game in progress keeps its tally.
    private func startRecordingInstead() {
        let kept = score
        flow = RacketGameFlow(filming: true, unitIndex: flow.unitIndex, options: flow.options, startInWarmup: true)
        score = kept
        machine = nil
        stage = .camera
        openCamera()
    }

    // MARK: The Watch

    private var watchContext: RacketWatchContext {
        var c = RacketWatchContext(ex)
        c.unitNumber = flow.unitIndex + 1
        return c
    }

    private var watchState: RacketWatchState? {
        guard configured else { return nil }
        return RacketWatchBridge.gameCoverState(flow, machine: machine, context: watchContext, score: score,
                                                lastUnitLabel: lastUnitLabel, now: now)
    }

    private func handleWatch(_ command: RacketWatchCommand, now at: Date) {
        machineAct { $0.noteActivity(now: at); return [] }
        switch RacketWatchBridge.gameAction(command, phase: flow.phase) {
        case .startGame:
            if stage == .warmup { startRecording() } else if stage == .game { step { $0.startGame(now: at) } }
        case .point(let us): point(us: us, fromWatch: true)
        case .undo: undo()
        case .endGame: step { $0.endGame(matchOver: false, now: at) }
        case .endMatch:
            if isScoring(flow.phase) || flow.phase == .playing || isInterval(flow.phase) {
                step { $0.endGame(matchOver: true, now: at) }
            } else {
                step { $0.endMatch() }
            }
        case .mark: mark()
        case .pauseTimer:
            step { f in f.pauseBreak(now: at); f.pauseInterval(now: at); return [] }
        case .resumeTimer:
            step { f in f.resumeBreak(now: at); f.resumeInterval(now: at); return [] }
        case .add(let sec):
            if case .countdown = flow.phase { step { $0.extendCountdown(by: sec); return [] } }
            else { step { f in f.addBreak(sec); f.addInterval(sec); return [] } }
        case .skip:
            if isInterval(flow.phase) { step { $0.endInterval() } } else { step { $0.skipBreak(now: at); return [] } }
        case .keepPlaying: machineAct { $0.keepPlaying(now: at); return [] }
        case .stopRecording:
            machineAct { $0.keepPlaying(now: at); return [] }
            step { $0.endGame(matchOver: true, now: at) }
        case .none: break
        }
    }

    // MARK: Camera check (NoModelCamera)

    private var cameraCheck: some View {
        RacketCameraCheckPanel(sport: sport, fake: recorder.fake, accessDenied: accessDenied,
                               continueTitle: "Continue to warmup", onCancel: onClose,
                               onContinue: { stage = .warmup })
            .padding(16)
    }

    // MARK: Warmup

    private var warmup: some View {
        VStack(spacing: 12) {
            HStack {
                Button { stage = .camera } label: { Label("Back", systemImage: "chevron.left") }
                    .accessibilityIdentifier("racket.warmup.back")
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Camera ready").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.perfFresh)
                        Spacer()
                        Text("Not recording").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                            .accessibilityIdentifier("racket.warmup.status")
                    }
                    Text("Warmup").font(.system(size: 30, weight: .bold)).accessibilityIdentifier("racket.warmup.title")
                    Text(RacketGameCopy.warmupLine(unit)).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    RacketBox {
                        Text("How to record this match").font(.system(size: 15, weight: .semibold))
                        RacketChips(options: [RacketRecordingMode.byUnit, .everything],
                                    label: { $0.label(for: .match, unit: unit) },
                                    selection: $choice, idPrefix: "racket.warmup.mode")
                        RacketTrackingSwitchRow(line: RacketGameCopy.warmupTrackingLine(sport))
                    }
                    RacketBox {
                        Text("Who serves first? Optional").font(.system(size: 15, weight: .semibold))
                        RacketChips(options: ["us", "them", "skip"],
                                    label: { $0 == "us" ? sides.us : $0 == "them" ? sides.them : "Skip" },
                                    selection: Binding(get: { firstServer?.rawValue ?? "skip" },
                                                       set: { firstServer = RacketServe.Side(rawValue: $0) }),
                                    idPrefix: "racket.warmup.serve")
                    }
                    RacketBox {
                        Text("During play, show").font(.system(size: 15, weight: .semibold))
                        RacketChips(options: RacketRecordingShow.allCases, label: { $0.label }, selection: $show,
                                    idPrefix: "racket.warmup.show")
                        Text("Switch any time. Camera and live tracking may warm the phone more.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            RacketWideButton("Start recording", id: "racket.warmup.start") { startRecording() }
            Text("Or tap Start on your Watch. Everything checks space first.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }

    // MARK: The game screen

    @ViewBuilder private var game: some View {
        ZStack {
            VStack(spacing: 12) {
                gameHeader
                if flow.filming { filmingContent } else { scoreOnlyContent }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let m = machine, flow.filming, !m.isEnded, let reason = m.interruption {
                RacketOverlay {
                    RacketInterruptionPanel(
                        header: RacketRecordingRoutes.header(mode: .match, recording: .byUnit, unit: unit,
                                                             unitNumber: flow.unitIndex + 1, block: nil, blocks: 1),
                        reason: reason, savedUpToSec: m.log?.savedUpToSec ?? 0,
                        endLabel: RacketRecordingRoutes.endLabel(.score), allowsKeepScoring: true,
                        onResume: { machineAct { $0.resume(now: Date()) } },
                        onKeepScoring: keepScoringWithoutVideo,
                        onEnd: { step { $0.endGame(matchOver: true, now: Date()) }; machineAct { $0.end(now: Date()) } })
                }
            } else if let m = machine, flow.filming, !m.isEnded, let asked = m.stillPlayingAskedAt {
                let minutes = Int((m.stillPlayingSec ?? 1800) / 60)
                RacketOverlay {
                    RacketStillPlayingPanel(
                        minutes: minutes, secondsLeft: max(0, RacketStillPlaying.answerWindowSec - now.timeIntervalSince(asked)),
                        againLine: RacketStillPlaying.again(minutes: minutes, everythingMinutes: defaults.stillPlayingEverythingMin),
                        onKeep: { machineAct { $0.keepPlaying(now: Date()); return [] } },
                        onStop: {
                            machineAct { $0.keepPlaying(now: Date()); return [] }
                            step { $0.endGame(matchOver: true, now: Date()) }
                        })
                }
            }
        }
    }

    /// "● Recording 09:41 · Game 1 · Phone OK" / "Ⅱ Recording paused · Game 1 saved" / "Not recording · Game 1".
    private var gameHeader: some View {
        let recorded = machine?.log?.recordedSec(now: now) ?? 0
        let capturing = machine?.capturing == true
        let center: String = {
            switch flow.phase {
            case .breakTime, .breakPaused, .breakDone:
                return "\(RacketGameCopy.unitTitle(unit, index: max(0, flow.unitIndex - 1))) saved"
            case .countdown: return unitTitle
            default: return unitTitle
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if case .countdown = flow.phase {
                    Text("Starting soon").foregroundStyle(SnappetColor.perfFresh)
                } else if !flow.filming || machine == nil || machine?.isEnded == true {
                    Text("Not recording").foregroundStyle(SnappetColor.textSecondary)
                } else if capturing {
                    HStack(spacing: 6) {
                        Circle().fill(SnappetColor.perfHard).frame(width: 8, height: 8)
                        Text("Recording \(RacketClock.recordingHeader(recorded))").monospacedDigit()
                    }
                    .foregroundStyle(SnappetColor.perfHard)
                } else if let i = machine?.interruption {
                    Text(i.canResume ? "Ⅱ Recording stopped" : "■ Recording ended").foregroundStyle(SnappetColor.perfModerate)
                } else {
                    Text("Ⅱ Recording paused").foregroundStyle(SnappetColor.perfModerate)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .accessibilityIdentifier("racket.game.status")
            Spacer(minLength: 4)
            Text(center).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("racket.game.unit")
            if flow.filming, isPlaying(flow.phase) {
                Spacer(minLength: 4)
                Text(rightLabel.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(rightLabel.color)
                    .accessibilityIdentifier("racket.game.phone")
            }
        }
    }

    private var rightLabel: (text: String, color: Color) {
        if isInterval(flow.phase) {
            return flow.options.pauseRecordingInInterval ? ("Recording paused", SnappetColor.textSecondary)
                                                         : ("Keeps recording", SnappetColor.textSecondary)
        }
        return thermal == .ok ? (thermal.headerLabel, SnappetColor.perfFresh) : (thermal.headerLabel, SnappetColor.perfModerate)
    }

    @ViewBuilder private var filmingContent: some View {
        switch flow.phase {
        case .warmup, .ended: Spacer()
        case .interval, .intervalPaused: intervalPanel
        case .breakTime, .breakPaused, .breakDone: breakPanel
        case .countdown(let endsAt): countdownPanel(endsAt)
        case .playing, .scoring:
            if thermal != .ok {
                warmContent
            } else {
                playingContent
                if show != .dim { RacketTrackingOffRow() }
                RacketShowSwitcher(show: $show)
                nextAndStop
            }
        }
    }

    private var server: RacketServe.Side? {
        RacketServe.server(sport: sport, firstServer: firstServer, unitIndex: flow.unitIndex,
                           previous: Array(ex.racketUnits.prefix(flow.unitIndex)), points: score.points)
    }

    private var caption: String {
        RacketGameCopy.scoreCaption(sport: sport, unitIndex: flow.unitIndex, score: score, server: server, them: sides.them,
                                    fromWatch: scoreFromWatch)
    }

    private var inTiebreak: Bool { score.rules.kind == .sets && score.tally.inTiebreak && !score.isFinished }

    @ViewBuilder private var playingContent: some View {
        switch show {
        case .dim:
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                if inTiebreak { tiebreakBanner } else { bigScore(size: 76) }
                Text(RacketGameCopy.recordingLine(sport)).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("racket.game.line")
                RacketWideButton("Mark this moment", id: "racket.game.mark", primary: false) { mark() }
                RacketTrackingOffRow()
                Spacer(minLength: 0)
            }
        case .camera:
            VStack(spacing: 10) {
                Color.clear.racketPreviewSlot()
                    .overlay {
                        if recorder.fake {
                            Text("Camera preview shows here on a device")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("racket.game.preview")
                HStack(spacing: 10) {
                    RacketStat(value: score.display, label: inTiebreak ? "Tiebreak" : "Score").accessibilityIdentifier("racket.game.cameraScore")
                    RacketStat(value: RacketClock.elapsed(gameSec), label: "\(unit.noun.capitalized) time")
                }
                Text(RacketGameCopy.cameraTrackingOffLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        case .stats:
            let tags = RacketTagSummary.make(machine?.log?.allRallies ?? [], sport: sport)
            RacketStatsOffPanel(score: score.display, tags: tags, sides: sides, unit: unit,
                                gameSec: gameSec, sessionSec: machine?.log?.recordedSec(now: now) ?? 0,
                                pointsLabel: RacketGameCopy.pointsLabel(sport),
                                points: RacketRecordStats.pointsPlayed(score), heartRate: heartRate,
                                afterLine: RacketGameCopy.statsAfterLine(sport))
        }
    }

    private var gameSec: TimeInterval { flow.gameStartedAt.map { now.timeIntervalSince($0) } ?? 0 }

    private func bigScore(size: CGFloat, caption showsCaption: Bool = true) -> some View {
        VStack(spacing: 4) {
            Text(score.display).font(.system(size: size, weight: .light)).monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("racket.game.score")
            // ScoreOnly has no caption: its header already says "Game 1" (XxScoreOnly boards).
            if showsCaption {
                Text(caption).font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.game.caption")
            }
        }
    }

    /// TnTiebreak: "Tiebreak 5 – 4 · Set 1 · games 6–6 · first to 7, win by 2".
    private var tiebreakBanner: some View {
        VStack(spacing: 8) {
            Text("Tiebreak").font(.system(size: 17, weight: .semibold)).accessibilityIdentifier("racket.game.tiebreak")
            Text(score.display).font(.system(size: 76, weight: .light)).monospacedDigit()
                .accessibilityIdentifier("racket.game.score")
            Text(RacketGameCopy.tiebreakLine(unitIndex: flow.unitIndex, gamesTo: ex.racketFormat.pointsTo))
                .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.game.tiebreakLine")
            Text(RacketGameCopy.tiebreakWatchLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SnappetColor.hairline))
        }
    }

    /// Warm / PhoneWarm: the camera view pauses, recording continues.
    private var warmContent: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("▲ Camera view and live tracking paused").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SnappetColor.perfModerate)
                    .accessibilityIdentifier("racket.game.warm")
                Text("Your recording is safe and continues. You can still keep score and mark moments.")
                    .font(.system(size: 14))
                Text("Shade the phone or take off its case if you can.").font(SnappetType.detail)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.perfModerate, lineWidth: 1))
            Spacer(minLength: 0)
            bigScore(size: 64)
            RacketWideButton("Mark this moment", id: "racket.game.mark", primary: false) { mark() }
            Spacer(minLength: 0)
            nextAndStop
        }
    }

    private var nextAndStop: some View {
        HStack(spacing: 10) {
            RacketWideButton("Next \(unit.noun)", id: "racket.game.next", primary: false) {
                step { $0.endGame(matchOver: false, now: Date()) }
            }
            RacketStopButton(title: "Stop", id: "racket.game.stop") { step { $0.endGame(matchOver: true, now: Date()) } }
        }
    }

    // MARK: Interval (BdInterval)

    private var intervalPanel: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            if let d = flow.display(now: now) { RacketTimerRing(display: d) }
            Text("Interval. Someone reached \(flow.options.intervalAt ?? 11) first.").font(.system(size: 15))
                .foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.interval.line")
            HStack(spacing: 10) {
                if case .intervalPaused = flow.phase {
                    RacketWideButton("Resume", id: "racket.interval.resume", primary: false) { step { $0.resumeInterval(now: Date()); return [] } }
                } else {
                    RacketWideButton("Pause", id: "racket.interval.pause", primary: false) { step { $0.pauseInterval(now: Date()); return [] } }
                }
                RacketWideButton("+30 s", id: "racket.interval.add30", primary: false) { step { $0.addInterval(30); return [] } }
            }
            RacketWideButton("Skip interval", id: "racket.interval.skip") { step { $0.endInterval() } }
            RacketBox {
                Toggle(isOn: Binding(get: { flow.options.pauseRecordingInInterval },
                                     set: { on in step { $0.setPauseRecordingInInterval(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause recording during intervals").font(.system(size: 15, weight: .semibold))
                        Text("Off keeps one clip for the game").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("racket.interval.pauseRecording")
            }
            Text("The game continues without a new clip or a new score.").font(SnappetType.detail)
                .foregroundStyle(SnappetColor.textSecondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Break (GameBreak)

    private var breakPanel: some View {
        let next = flow.unitIndex + 1
        return VStack(spacing: 14) {
            Spacer(minLength: 0)
            if let d = flow.display(now: now) { RacketTimerRing(display: d) }
            Text(RacketGameCopy.breakLine(unit: unit, next: next, autoStart: flow.breakAutoStart))
                .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.break.line")
            if flow.phase == .breakDone {
                RacketWideButton("Start \(unit.noun) \(next)", id: "racket.break.start") { step { $0.startGame(now: Date()) } }
            } else {
                HStack(spacing: 8) {
                    if case .breakPaused = flow.phase {
                        RacketWideButton("Resume", id: "racket.break.resume", primary: false) { step { $0.resumeBreak(now: Date()); return [] } }
                    } else {
                        RacketWideButton("Pause", id: "racket.break.pause", primary: false) { step { $0.pauseBreak(now: Date()); return [] } }
                    }
                    RacketWideButton("+30 s", id: "racket.break.add30", primary: false) { step { $0.addBreak(30); return [] } }
                    RacketWideButton("+1 min", id: "racket.break.add60", primary: false) { step { $0.addBreak(60); return [] } }
                }
                RacketWideButton("Skip break, start \(unit.noun.capitalized) \(next)", id: "racket.break.skip") {
                    step { $0.skipBreak(now: Date()); return [] }
                }
            }
            RacketBox {
                Toggle(isOn: Binding(get: { flow.breakAutoStart }, set: { on in step { $0.setBreakAutoStart(on); return [] } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-start").font(.system(size: 15, weight: .semibold))
                        Text("Off: you start the next \(unit.noun) yourself").font(SnappetType.detail)
                            .foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                .tint(SnappetColor.brand)
                .accessibilityIdentifier("racket.break.autoStart")
            }
            Text("Your Watch taps you before it starts.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            Spacer(minLength: 0)
            Button("End match") { step { $0.endMatch() } }
                .font(.system(size: 15, weight: .semibold))
                .accessibilityIdentifier("racket.break.endMatch")
        }
    }

    // MARK: Countdown (GameCountdown)

    private func countdownPanel(_ endsAt: Date) -> some View {
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        return VStack(spacing: 14) {
            Spacer()
            Text("\(left)").font(.system(size: 140, weight: .light)).monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("racket.countdown.number")
            Text(flow.filming ? "Recording starts at zero" : "The \(unit.noun) starts at zero")
                .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
            Spacer()
            HStack(spacing: 10) {
                RacketWideButton("Wait", id: "racket.countdown.wait") { step { $0.wait(); return [] } }
                RacketWideButton("+30 s", id: "racket.countdown.add30", primary: false) { step { $0.extendCountdown(by: 30); return [] } }
            }
            Text("Wait returns to a paused break timer.").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
        }
    }

    // MARK: ScoreOnly

    @ViewBuilder private var scoreOnlyContent: some View {
        switch flow.phase {
        case .breakTime, .breakPaused, .breakDone: breakPanel
        case .countdown(let endsAt): countdownPanel(endsAt)
        case .interval, .intervalPaused: intervalPanel
        default:
            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    Button("Close") { onClose() }.font(.system(size: 15)).accessibilityIdentifier("racket.scoreOnly.close")
                }
                Spacer(minLength: 0)
                if inTiebreak { tiebreakBanner } else { bigScore(size: 84, caption: false) }
                Text("Tap who won each point. A Watch works too.").font(.system(size: 15))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.scoreOnly.line")
                HStack(spacing: 10) {
                    pointButton("\(sides.us) +1", id: "racket.scoreOnly.us", filled: true) { point(us: true, fromWatch: false) }
                    pointButton("\(sides.them) +1", id: "racket.scoreOnly.them", filled: false) { point(us: false, fromWatch: false) }
                }
                HStack(spacing: 10) {
                    RacketWideButton("Undo", id: "racket.scoreOnly.undo", primary: false) { undo() }
                        .disabled(score.isEmpty)
                    RacketWideButton("End \(unit.noun)", id: "racket.scoreOnly.end", primary: false) {
                        step { $0.endGame(matchOver: false, now: Date()) }
                    }
                }
                Button("Start recording instead") { startRecordingInstead() }
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("racket.scoreOnly.record")
                Spacer(minLength: 0)
            }
        }
    }

    private func pointButton(_ title: String, id: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(filled ? Color.black : SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 86)
                .background(filled ? SnappetColor.brand : SnappetColor.brand.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SnappetColor.brand.opacity(filled ? 0 : 0.8), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

extension RacketRecordingShow {
    /// The game-by-game screen opens on what Warmup's "During play, show" picked. The board's default is Dim; device
    /// feedback round 2 ("the camera view is dark — nothing visible") makes it the camera, as record everything already
    /// does at the user's request (round 1).
    static let initialGame: RacketRecordingShow = .camera
}

// MARK: - Court guide (placeholder for the court check)

/// A placeholder for the court check, which isn't built (user, device feedback round 2): corner brackets and the
/// sport's playing-area outline over the live preview, labelled as a guide — it detects nothing.
struct RacketCourtGuide: View {
    let sport: RacketSport

    private var label: String {
        sport == .tableTennis ? "Guide only: fit the whole table inside" : "Guide only: fit the whole court inside"
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // Corner brackets.
                Path { p in
                    let inset: CGFloat = 12, len: CGFloat = 22
                    for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (w - inset, inset, -1.0, 1.0),
                                           (inset, h - inset, 1.0, -1.0), (w - inset, h - inset, -1.0, -1.0)] {
                        p.move(to: CGPoint(x: x + dx * len, y: y)); p.addLine(to: CGPoint(x: x, y: y))
                        p.addLine(to: CGPoint(x: x, y: y + dy * len))
                    }
                }
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // The playing area seen from behind and above: a trapezoid, narrower at the far end.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.12, y: h * 0.84))
                    p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.84))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.30))
                    p.addLine(to: CGPoint(x: w * 0.28, y: h * 0.30))
                    p.closeSubpath()
                    p.move(to: CGPoint(x: w * 0.20, y: h * 0.57)); p.addLine(to: CGPoint(x: w * 0.80, y: h * 0.57))
                }
                .stroke(SnappetColor.brand.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                VStack {
                    Spacer()
                    Text(label).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("racket.camera.guide")
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Score after a game (SaveGame / XxScore)

/// The score sheet after a game played on the game-by-game screen (or without video): Cancel · Game 1 · Later, the
/// two steppers filled in from the tally, the break options, "Save, start break" / "Save, match over".
struct RacketSaveGameSheet: View {
    let ex: SessionExercise
    let unitIndex: Int
    /// The tally for this game (Watch or phone taps); its result fills the steppers.
    let live: RacketLiveScore
    let fromWatch: Bool
    let filming: Bool
    @Binding var options: RacketGameFlow.Options
    let durationSec: TimeInterval?
    /// The game's log, and whether a break starts (Later and "Save, start break") or the match is over.
    let onSave: (SetLog, Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mine = 0
    @State private var theirs = 0
    @State private var tbMine = 7
    @State private var tbTheirs = 5
    @State private var configured = false
    @State private var custom = false

    private var format: RacketFormat { ex.racketFormat }
    private var sport: RacketSport { format.sport }
    private var unit: RacketUnit { sport.unit }
    private var isSTB: Bool { format.isSuperTiebreak(index: unitIndex) }
    private var needsTB: Bool { !isSTB && sport.usesSets && RacketScoring.needsTiebreak(mine, theirs, gamesTo: format.pointsTo) }
    private var sides: (us: String, them: String) { RacketWatchCopy.sides(opponent: ex.opponent, doubles: ex.isDoubles) }
    private var maxValue: Int { isSTB ? 40 : sport.usesSets ? 13 : (format.cap ?? 60) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("Cancel") { onCancel(); dismiss() }.accessibilityIdentifier("racket.save.cancel")
                    Spacer()
                    Text(isSTB ? "Super tiebreak" : RacketGameCopy.unitTitle(unit, index: unitIndex)).font(.headline)
                    Spacer()
                    Button("Later") { later() }.accessibilityIdentifier("racket.save.later")
                }
                Text("Final score").font(.system(size: 28, weight: .bold))
                Text(RacketGameCopy.scoreSubtitle(sport: sport, fromWatch: fromWatch, cap: format.cap))
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.save.subtitle")
                HStack(spacing: 0) {
                    column(sides.us, $mine, id: "mine")
                    column(sides.them, $theirs, id: "theirs")
                }
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if needsTB { tiebreakRow }
                RacketBox {
                    Toggle(isOn: $options.autoStart) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start next \(unit.noun) automatically").font(.system(size: 15, weight: .semibold))
                            Text(filming ? "Recording starts when the break ends" : "The next \(unit.noun) starts when the break ends")
                                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .tint(SnappetColor.brand)
                    .accessibilityIdentifier("racket.save.autoStart")
                    Text("Break before next \(unit.noun)").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(RacketGameCopy.breakChips(sport), id: \.self) { sec in
                            chip(RacketClock.mmss(TimeInterval(sec)), on: !custom && options.breakSec == sec,
                                 id: "racket.save.break.\(sec)") { custom = false; options.breakSec = sec }
                        }
                        chip("Custom", on: custom, id: "racket.save.break.custom") { custom = true }
                    }
                    if custom {
                        Stepper("Break \(RacketClock.mmss(TimeInterval(options.breakSec)))",
                                value: $options.breakSec, in: 15...900, step: 15)
                            .accessibilityIdentifier("racket.save.break.customStepper")
                    }
                    if filming {
                        Toggle(isOn: $options.pauseRecordingInBreak) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pause recording during the break").font(.system(size: 15, weight: .semibold))
                                Text("Each \(unit.noun) saves as its own clip").font(SnappetType.detail)
                                    .foregroundStyle(SnappetColor.textSecondary)
                            }
                        }
                        .tint(SnappetColor.brand)
                        .accessibilityIdentifier("racket.save.pauseRecording")
                    }
                }
                RacketWideButton("Save, start break", id: "racket.save.startBreak") { save(startBreak: true) }
                RacketWideButton("Save, match over", id: "racket.save.matchOver", primary: false) { save(startBreak: false) }
                Text("Auto-start stops once the score decides the match.")
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
        .onAppear {
            guard !configured else { return }
            configured = true
            custom = !RacketGameCopy.breakChips(sport).contains(options.breakSec)
            if !live.isEmpty {
                let r = live.provisionalResult
                mine = r.scoreFor; theirs = r.scoreAgainst
                tbMine = r.tiebreakFor ?? 7; tbTheirs = r.tiebreakAgainst ?? 5
            } else {
                (mine, theirs) = RacketScoring.initialScore(format: format, superTiebreak: isSTB)
            }
        }
    }

    private func save(startBreak: Bool) {
        var log = SetLog(durationSec: (durationSec ?? 0) > 0 ? durationSec : nil)
        log.scoreFor = mine
        log.scoreAgainst = theirs
        if needsTB { log.tiebreakFor = tbMine; log.tiebreakAgainst = tbTheirs }
        if isSTB { log.superTiebreak = true }
        onSave(log, startBreak)
        dismiss()
    }

    /// "Later: confirm after": the game is logged from the Watch's tally ("from Watch", counted until confirmed), else
    /// "Score unconfirmed" (counts for neither side), and the break starts.
    private func later() {
        var log: SetLog
        if fromWatch && !live.isEmpty {
            log = SetLog(watchResult: live.provisionalResult, durationSec: durationSec)
        } else {
            log = SetLog(durationSec: (durationSec ?? 0) > 0 ? durationSec : nil)
            log.scoreUnconfirmed = true
        }
        onSave(log, true)
        dismiss()
    }

    private func column(_ who: String, _ value: Binding<Int>, id: String) -> some View {
        VStack(spacing: 8) {
            Text(who).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
            Text("\(value.wrappedValue)").font(.system(size: 52, weight: .light)).monospacedDigit()
                .accessibilityIdentifier("racket.save.\(id)")
            HStack(spacing: 10) {
                stepButton("−", id: "\(id).minus") { value.wrappedValue = max(0, value.wrappedValue - 1) }
                stepButton("+", id: "\(id).plus") { value.wrappedValue = min(maxValue, value.wrappedValue + 1) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(symbol).font(.system(size: 22, weight: .semibold))
                .frame(width: 52, height: 40)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.save.\(id)")
    }

    private var tiebreakRow: some View {
        HStack {
            Text("Tiebreak").font(.subheadline.weight(.semibold))
            Spacer()
            Stepper("\(tbMine)", value: $tbMine, in: 0...40).fixedSize()
            Text("–").foregroundStyle(SnappetColor.textSecondary)
            Stepper("\(tbTheirs)", value: $tbTheirs, in: 0...40).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("racket.save.tiebreak")
    }

    private func chip(_ label: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(label).font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? SnappetColor.brand : SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(on ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? SnappetColor.brand : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Shared pieces (both recording screens)

/// StatsOff / LiveStatsOff: your tags, game / session time, points, heart rate, how rallies ended.
struct RacketStatsOffPanel: View {
    let score: String
    let tags: RacketTagSummary
    let sides: (us: String, them: String)
    let unit: RacketUnit
    let gameSec: TimeInterval
    let sessionSec: TimeInterval
    let pointsLabel: String
    let points: Int?
    let heartRate: Double?
    let afterLine: String

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Text(score).font(.system(size: 40, weight: .light)).monospacedDigit()
                        .accessibilityIdentifier("racket.rec.score")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Your tags").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                        Text(RacketRecordStats.tagsLine(tags, sides: sides)).font(.system(size: 15, weight: .semibold))
                            .accessibilityIdentifier("racket.rec.stats.tags")
                    }
                }
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        tile(RacketClock.elapsed(gameSec), "\(unit.noun.capitalized) time", id: "racket.rec.stats.gameTime")
                        tile(RacketClock.elapsed(sessionSec), "Session time", id: "racket.rec.stats.sessionTime")
                    }
                    GridRow {
                        tile(points.map(String.init) ?? "–", pointsLabel, id: "racket.rec.stats.points")
                        tile(heartRate.map { "\(Int($0.rounded()))" } ?? "–", "Heart rate", id: "racket.rec.stats.hr")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("How rallies ended").font(.system(size: 15, weight: .semibold))
                    if tags.endings.isEmpty {
                        Text("No endings tagged yet").font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    } else {
                        let top = tags.endings.map(\.count).max() ?? 1
                        ForEach(tags.endings, id: \.ending) { e in
                            HStack(spacing: 8) {
                                Text(e.ending.label).font(SnappetType.detail).frame(width: 90, alignment: .leading)
                                GeometryReader { g in
                                    Capsule().fill(SnappetColor.brand)
                                        .frame(width: max(4, g.size.width * Double(e.count) / Double(max(1, top))))
                                }
                                .frame(height: 8)
                                Text("\(e.count)").font(SnappetType.detail.monospacedDigit())
                            }
                        }
                    }
                    Text(tags.sourceLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.rec.stats.source")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(afterLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("racket.rec.stats.after")
            }
        }
        .accessibilityIdentifier("racket.rec.stats")
    }

    private func tile(_ v: String, _ k: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 26, weight: .light)).monospacedDigit()
            Text(k).font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// "Live tracking off · Turn on" on the boards. Live tracking during play isn't built (step 6), so the row keeps its
/// place and says so: "Live tracking off · Not available yet", disabled (device feedback round 2: placeholders say what
/// isn't built, never pretend).
struct RacketTrackingOffRow: View {
    var body: some View {
        HStack {
            Text("Live tracking off").font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
            Spacer()
            Button(RacketFeatureState.notAvailableYet.label) {}
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .disabled(true)
                .accessibilityIdentifier("racket.rec.trackingTurnOn")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.rec.trackingRow")
    }
}

/// Warmup's "Live tracking · Off: rallies are found after the match" switch, off and disabled until step 6.
struct RacketTrackingSwitchRow: View {
    let line: String
    var body: some View {
        Toggle(isOn: .constant(false)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live tracking").font(.system(size: 15, weight: .semibold))
                Text(line).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                Text(RacketFeatureState.notAvailableYet.label).font(SnappetType.detail.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .disabled(true)
        .accessibilityIdentifier("racket.warmup.tracking")
    }
}

/// Dim · Camera · Stats.
struct RacketShowSwitcher: View {
    @Binding var show: RacketRecordingShow
    var body: some View {
        HStack(spacing: 8) {
            ForEach(RacketRecordingShow.allCases, id: \.self) { v in
                Button { show = v; Haptics.tap() } label: {
                    Text(v.label)
                        .font(.system(size: 14, weight: show == v ? .semibold : .medium))
                        .foregroundStyle(show == v ? SnappetColor.brand : SnappetColor.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(show == v ? SnappetColor.brand.opacity(0.12) : Color(white: 0.08),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(show == v ? SnappetColor.brand : SnappetColor.hairline, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.rec.show.\(v.rawValue)")
                .accessibilityAddTraits(show == v ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.rec.show")
    }
}

/// A row of selectable chips (Warmup, the match form).
struct RacketChips<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    let idPrefix: String
    var idFor: (T) -> String = { "\($0)" }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o; Haptics.tap() } label: {
                    Text(label(o)).font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? SnappetColor.brand : SnappetColor.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .padding(.horizontal, 4)
                        .background(on ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(on ? SnappetColor.brand : .clear, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix).\(idFor(o))")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The boards' grouped box.
struct RacketBox<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct RacketWideButton: View {
    let title: String
    let id: String
    var primary = true
    let action: () -> Void

    init(_ title: String, id: String, primary: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.primary = primary
        self.action = action
    }

    var body: some View {
        if primary {
            Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 30) }
                .buttonStyle(SnappetWidePrimaryStyle())
                .accessibilityIdentifier(id)
        } else {
            Button(action: action) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pagerOutline()
            .accessibilityIdentifier(id)
        }
    }
}

/// Stop: a red outline.
struct RacketStopButton: View {
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay(Capsule().strokeBorder(SnappetColor.perfHard, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The boards' stat: light numerals over a grey label, centred.
struct RacketStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 30, weight: .light)).monospacedDigit()
            Text(label).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct RacketOverlay<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(20)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(20)
        }
    }
}

/// Interrupted / InterruptedStop (review5 H1; V2.5: "Your Watch tells you it stopped.", and storage full also shows the
/// "If the phone got too hot" paragraph).
struct RacketInterruptionPanel: View {
    let header: String
    let reason: RacketInterruption
    let savedUpToSec: Double
    let endLabel: String
    let allowsKeepScoring: Bool
    let onResume: () -> Void
    let onKeepScoring: () -> Void
    let onEnd: () -> Void

    var body: some View {
        Text(header).snappetLabel().accessibilityIdentifier("racket.int.header")
        Text(reason.headline).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("racket.int.reason")
        if reason.canResume {
            line("Everything up to \(RacketClock.elapsed(savedUpToSec)) is saved in Photos.")
            Text("This also happens when").font(.system(size: 13, weight: .semibold))
            line("Snappet leaves the screen or the phone locks. Full storage or overheating can’t resume.")
            RacketWideButton("Resume recording", id: "racket.int.resume", action: onResume)
            line("Your Watch tells you it stopped. Resume on the phone: it starts a new part of the same game, drill block or recording.")
                .accessibilityIdentifier("racket.int.resumeLine")
        } else {
            line("Everything up to \(RacketClock.elapsed(savedUpToSec)) is saved in Photos."
                 + (reason == .storageFull ? " Free some space to record again." : ""))
            Text("If the phone got too hot").font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("racket.int.hotTitle")
            line("iOS stops the camera to protect it. Let it cool in the shade, then start a new recording.")
            if allowsKeepScoring {
                RacketWideButton("Keep scoring without video", id: "racket.int.keepScoring", primary: false, action: onKeepScoring)
            }
        }
        if reason.canResume {
            // TtInterrupted: End is a quiet accent link under Resume.
            Button(endLabel, action: onEnd)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .accessibilityIdentifier("racket.int.end")
        } else {
            // TtInterruptedStop: End is the primary action.
            RacketWideButton(endLabel, id: "racket.int.end", action: onEnd)
        }
    }

    private func line(_ s: String) -> some View {
        Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Still playing? (StillPlaying board; the configured threshold everywhere, review5 M4).
struct RacketStillPlayingPanel: View {
    let minutes: Int
    let secondsLeft: TimeInterval
    let againLine: String
    let onKeep: () -> Void
    let onStop: () -> Void

    var body: some View {
        Text("Still playing?").font(.system(size: 22, weight: .semibold)).accessibilityIdentifier("racket.still.title")
        line(RacketStillPlaying.reason(minutes: minutes))
        line("Recording stops in \(RacketClock.mmss(secondsLeft)) if there’s no answer. Everything so far stays saved.")
        RacketWideButton("Keep recording", id: "racket.still.keep", action: onKeep)
        RacketStopButton(title: "Stop recording", id: "racket.still.stop", action: onStop)
        line(againLine).accessibilityIdentifier("racket.still.again")
    }

    private func line(_ s: String) -> some View {
        Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
