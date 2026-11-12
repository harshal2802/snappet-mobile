import SwiftUI
import Charts

// MARK: - Drill screens (prompt 250, issue #438 parity)
//
// One full-screen cover for a drill in every recording mode (block by block, everything, don't film): Camera check →
// BlockStart → Block (BlockOff / BlockAll) ⇄ Paused → Rest (RestOff / RestEverything) ⇄ RestPaused → … → Review →
// DrillTrend / Drill videos. Thin renderer over the pure `RacketRecordingMachine` (timers, capture, interruptions,
// Still playing?) and `RacketDrillFlow.swift` (copy, review, trend); the camera is `Services/RacketRecorder.swift`.
// The recording screens keep ONE camera preview for the cover's life (device feedback round 2).

/// What the host presents: a drill's cover, at the camera check (or its countdown without video), or straight at the
/// review (the drill page's "Review drill").
struct RacketDrillCoverTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
    /// Record everything's quality from the storage check; nil ⇒ the Settings default.
    var quality: RacketRecordingQuality? = nil
    var reviewOnly = false
}

struct RacketDrillCover: View {
    /// The drill, live from the host (its blocks update as they're logged).
    let ex: SessionExercise
    let defaults: RacketRecordingDefaults
    var quality: RacketRecordingQuality? = nil
    var reviewOnly = false
    /// Past sessions (Review's "Last time", DrillTrend).
    let history: [WorkoutSession]
    /// The session, for Drill videos.
    let session: WorkoutSession
    var heartRate: Double? = nil
    /// A block finished (absolute index, seconds played): log it.
    let onBlockLogged: (Int, TimeInterval) -> Void
    /// Rest logging: change a logged block (its longest rally, made / tried, feel).
    let onEditBlock: (Int, (inout SetLog) -> Void) -> Void
    /// A Photos part was saved, with the block it belongs to (block by block; nil when recording everything).
    let onPartSaved: (RecordedClip, Int?) -> Void
    let onLog: (RacketRecordingLog) -> Void
    /// Review "Done": back to the session hub.
    let onDone: () -> Void
    let onClose: () -> Void

    @State private var recorder = RacketRecorder()
    @State private var machine: RacketRecordingMachine?
    @State private var now = Date()
    @State private var show: RacketRecordingShow = .camera
    @State private var thermal: RacketThermalLevel = .ok
    @State private var configured = false
    @State private var accessDenied = false
    @State private var idleTimerWas = false
    @State private var watchToken: UUID?
    @State private var confirmFinish = false
    /// Blocks whose number waits for the scan ("Find rallies after the drill").
    @State private var findAfter: Set<Int> = []
    @State private var videos: RacketVideosTarget?
    @State private var reviewPath: [RacketDrillRoute] = []

    private var sport: RacketSport { ex.racketSport ?? ex.racketFormat.sport }
    private var title: String { ex.displayName ?? "Drill" }
    private var recording: RacketRecordingMode { machine?.recording ?? ex.racketRecording }
    private var filming: Bool { recording != .off }

    var body: some View {
        ZStack {
            if reviewOnly || machine?.isEnded == true {
                review
            } else if let m = machine {
                screen(m)
            }
        }
        .racketPersistentPreview(session: recorder.session, fake: recorder.fake)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(!(reviewOnly || machine?.isEnded == true))
        .onAppear { recorder.screenAppeared(); setUp() }
        .onDisappear(perform: tearDown)
        .onChange(of: watchState) { _, s in if let s { RacketWatchRelay.shared.publish(s) } }
        .task {
            guard !reviewOnly else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
                act { $0.tick(now: now) }
                if let m = machine, m.interruption == nil, !m.isEnded { recorder.ensureCapturing(m.capturing) }
            }
        }
        .confirmationDialog("Finish the drill?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("Finish drill", role: .destructive) { act { $0.end(now: Date()) } }
                .accessibilityIdentifier("racket.rec.confirmStop")
        } message: {
            Text(filming ? "Everything so far is saved in your Photos library." : "Your blocks so far are logged.")
        }
        .fullScreenCover(item: $videos) { t in
            RacketVideosCover(session: session, start: t.start) { videos = nil }
        }
    }

    // MARK: Set-up

    private func setUp() {
        guard !configured else { return }
        configured = true
        guard !reviewOnly else { return }
        idleTimerWas = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let plan = RacketDrillPlan(from: ex, defaults: defaults)
        var m = RacketRecordingMachine(kind: .drill(plan), recording: plan.recording,
                                       stillPlayingMinutes: defaults.stillPlayingMinutes(for: plan.recording), now: Date())
        m.startingBlock = ex.sets.count
        m.baseSetIndex = 0
        m.quality = quality ?? defaults.quality
        if plan.recording == .byUnit, let old = ex.racketRecordingLog, old.modeRaw == RacketRecordingMode.byUnit.rawValue {
            m.continueLog(old)
        }
        if plan.recording != .off {
            recorder.onThermal = { level in thermal = level }
            thermal = recorder.thermal
            recorder.onPartSaved = { clip in
                let index = machine?.log.flatMap { l in l.blockIndex(at: l.offset(clip.capturedAt)) }
                onPartSaved(clip, machine?.recording == .byUnit ? index : nil)
                act { m in
                    m.assetSaved(localIdentifier: clip.localIdentifier, startedAt: clip.capturedAt, durationSec: clip.durationSec)
                    return []
                }
            }
            recorder.onInterrupted = { reason in
                act { m in m.interrupt(reason, now: Date()); return [] }
                Haptics.warning()
            }
            Task {
                let ok = await RacketRecorder.requestAccess()
                accessDenied = !ok
                if ok { recorder.startPreview(quality: quality ?? defaults.quality) }
            }
            machine = m
        } else {
            // Don't film: no camera check — straight to the countdown to the first block.
            let effects = m.start(now: Date())
            machine = m
            perform(effects)
        }
        watchToken = RacketWatchRelay.shared.attach(ex.id) { command, at in handleWatch(command, now: at) }
        if let s = watchState { RacketWatchRelay.shared.publish(s) }
    }

    private func tearDown() {
        let was = idleTimerWas, id = ex.id, token = watchToken, review = reviewOnly
        recorder.screenDisappeared {
            if !review { UIApplication.shared.isIdleTimerDisabled = was }
            if let token { RacketWatchRelay.shared.detach(id, token: token) }
        }
    }

    // MARK: Plumbing

    private func act(_ event: (inout RacketRecordingMachine) -> [RacketRecordingMachine.Effect]) {
        guard var m = machine else { return }
        let before = m.log
        let effects = event(&m)
        machine = m
        perform(effects)
        if m.log != before, let log = m.log { onLog(log) }
    }

    private func perform(_ effects: [RacketRecordingMachine.Effect]) {
        for e in effects {
            switch e {
            case .startCapture: recorder.startCapture()
            case .stopCapture: recorder.stopCapture()
            case .logBlock(let i, let sec): onBlockLogged(i, sec)
            case .askStillPlaying: Haptics.warning()
            case .ended: Haptics.success(); recorder.stopPreview()
            case .continueWithoutVideo: onClose()
            }
        }
    }

    private var watchState: RacketWatchState? {
        guard let m = machine else { return nil }
        return RacketWatchBridge.coverState(m, context: RacketWatchContext(ex),
                                            score: RacketLiveScore(rules: .init(kind: .rally, pointsTo: 11)), now: now)
    }

    private func handleWatch(_ command: RacketWatchCommand, now at: Date) {
        guard var m = machine else { return }
        let before = m.log
        var score = RacketLiveScore(rules: .init(kind: .rally, pointsTo: 11))
        let out = RacketWatchBridge.apply(command, to: &m, score: &score, now: at)
        machine = m
        perform(out.effects)
        if m.log != before, let log = m.log { onLog(log) }
    }

    // MARK: The screen by phase

    @ViewBuilder private func screen(_ m: RacketRecordingMachine) -> some View {
        ZStack {
            VStack(spacing: 12) {
                switch m.phase {
                case .ready:
                    if filming { cameraCheck(m) } else { readyNoVideo(m) }
                case .countdown(let b, let endsAt): countdown(m, block: b, endsAt: endsAt)
                case .block(let b, _): blockScreen(m, block: b)
                case .blockPaused(let b, _): pausedScreen(m, block: b)
                case .rest(let a, _), .restDone(let a): restScreen(m, after: a)
                case .restPaused(let a, _): restPausedScreen(m, after: a)
                case .recordingMatch, .ended: EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let reason = m.interruption {
                RacketOverlay {
                    RacketInterruptionPanel(
                        header: RacketRecordingRoutes.header(mode: .drill, recording: m.recording, unit: sport.unit,
                                                             unitNumber: 1, block: m.currentBlock, blocks: m.plan?.blocks ?? 1),
                        reason: reason, savedUpToSec: m.log?.savedUpToSec ?? 0,
                        endLabel: RacketRecordingRoutes.endLabel(.drillReview), allowsKeepScoring: false,
                        onResume: { act { $0.resume(now: Date()) } }, onKeepScoring: {},
                        onEnd: { act { $0.end(now: Date()) } })
                }
            } else if let asked = m.stillPlayingAskedAt {
                let minutes = Int((m.stillPlayingSec ?? 1800) / 60)
                RacketOverlay {
                    RacketStillPlayingPanel(
                        minutes: minutes,
                        secondsLeft: max(0, RacketStillPlaying.answerWindowSec - now.timeIntervalSince(asked)),
                        againLine: m.recording == .byUnit
                            ? RacketStillPlaying.again(minutes: minutes, everythingMinutes: defaults.stillPlayingEverythingMin)
                            : RacketStillPlaying.again(minutes: minutes),
                        onKeep: { act { $0.keepPlaying(now: Date()); return [] } },
                        onStop: { act { $0.end(now: Date()) } })
                }
            }
        }
    }

    private var blocks: Int { machine?.plan?.blocks ?? 1 }

    /// "● Recording 03:12 · Block 2 of 3 · Phone OK" and its variants.
    private func headerRow(_ status: RacketDrillCopy.Status, center: String, showsPhone: Bool) -> some View {
        let color: Color = {
            switch status {
            case .recording, .recordingEverything: return SnappetColor.perfHard
            case .paused: return SnappetColor.perfModerate
            case .startingSoon: return SnappetColor.perfFresh
            case .notRecording: return SnappetColor.textSecondary
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(RacketDrillCopy.statusText(status)).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                .monospacedDigit()
                .accessibilityIdentifier("racket.rec.status")
            Spacer(minLength: 4)
            Text(center).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("racket.drill.header")
            if showsPhone {
                Spacer(minLength: 4)
                Text(thermal.headerLabel).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(thermal == .ok ? SnappetColor.perfFresh : SnappetColor.perfModerate)
                    .accessibilityIdentifier("racket.rec.phone")
            }
        }
    }

    private func status(_ m: RacketRecordingMachine) -> RacketDrillCopy.Status {
        switch m.recording {
        case .off: return .notRecording
        case .everything: return m.capturing ? .recordingEverything : .paused
        case .byUnit: return m.capturing ? .recording(seconds: m.log?.recordedSec(now: now) ?? 0) : .paused
        }
    }

    // MARK: Camera check (CameraCheck → NoModelCamera, drill)

    private func cameraCheck(_ m: RacketRecordingMachine) -> some View {
        RacketCameraCheckPanel(sport: sport, fake: recorder.fake, videoAspect: recorder.previewAspect,
                               accessDenied: accessDenied,
                               continueTitle: "Continue",
                               footnote: "Next: warmup for a match, or a countdown to block 1 for a drill.",
                               onCancel: onClose,
                               onContinue: { act { $0.startNextBlock(now: Date()) } })
    }

    private func readyNoVideo(_ m: RacketRecordingMachine) -> some View {
        VStack(spacing: 14) {
            headerRow(.notRecording, center: "Block \((m.currentBlock ?? 0) + 1) of \(blocks)", showsPhone: false)
            Spacer()
            Text(title).font(.system(size: 22, weight: .semibold))
            RacketWideButton("Start block \((m.currentBlock ?? 0) + 1)", id: "racket.rec.startBlock") {
                act { $0.startNextBlock(now: Date()) }
            }
            RacketWideButton("Back to the drill", id: "racket.rec.back", primary: false) { onClose() }
            Spacer()
        }
    }

    // MARK: BlockStart (DrillCountdown)

    private func countdown(_ m: RacketRecordingMachine, block b: Int, endsAt: Date) -> some View {
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        let first = b <= m.startingBlock
        return VStack(spacing: 14) {
            headerRow(.startingSoon, center: "Block \(b + 1) of \(blocks)", showsPhone: false)
            Spacer()
            Text("\(left)").font(.system(size: 150, weight: .light)).monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityIdentifier("racket.rec.countdown")
            Text(RacketDrillCopy.countdownLine(recording: m.recording, firstOfRun: first))
                .font(.system(size: 16)).foregroundStyle(SnappetColor.textSecondary).multilineTextAlignment(.center)
                .accessibilityIdentifier("racket.rec.countdownLine")
            Spacer()
            HStack(spacing: 10) {
                RacketWideButton("Wait", id: "racket.rec.wait") { act { $0.wait(now: Date()); return [] } }
                RacketWideButton("+30 s", id: "racket.rec.addCountdown", primary: false) {
                    act { $0.extendCountdown(by: 30, now: Date()); return [] }
                }
            }
            Text(m.recording == .off && first ? "Wait goes back to the start." : RacketDrillCopy.waitLine(firstOfRun: first))
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
        }
    }

    // MARK: Block (BlockOff · BlockAll · Block with tracking as BlockOff)

    @ViewBuilder private func blockScreen(_ m: RacketRecordingMachine, block b: Int) -> some View {
        let everything = m.recording == .everything
        headerRow(status(m), center: "Block \(b + 1) of \(blocks)", showsPhone: m.recording == .byUnit)
        if filming, thermal != .ok {
            RacketWarmPanel()
            ringOrCompact(m, compact: false)
            Spacer(minLength: 0)
        } else {
            switch filming ? show : .dim {
            case .camera:
                Color.clear.racketPreviewSlot()
                    .overlay { if recorder.fake { standIn } }
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("racket.rec.preview")
                ringOrCompact(m, compact: true)
                goalPanel(m, block: b)
            case .stats:
                ringOrCompact(m, compact: true)
                drillStats(m, block: b)
                Spacer(minLength: 0)
            case .dim:
                Spacer(minLength: 0)
                ringOrCompact(m, compact: false)
                if everything {
                    footnote(RacketDrillCopy.everythingFootnote)
                } else {
                    Text(RacketDrillCopy.blockLine(measure: ex.drillMeasure, recording: m.recording))
                        .font(.system(size: 16)).foregroundStyle(SnappetColor.textSecondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("racket.drill.line")
                }
                goalPanel(m, block: b)
                Spacer(minLength: 0)
            }
        }
        if filming {
            RacketTrackingOffRow()
            RacketShowSwitcher(show: $show)
        }
        HStack(spacing: 10) {
            RacketWideButton("Pause", id: "racket.rec.pause") { act { $0.pauseBlock(now: Date()) } }
            RacketWideButton("End block", id: "racket.rec.endBlock", primary: false) { act { $0.endBlock(now: Date()) } }
        }
    }

    private var standIn: some View {
        Text("Camera preview shows here on a device")
            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .accessibilityIdentifier("racket.rec.previewStandIn")
    }

    @ViewBuilder private func ringOrCompact(_ m: RacketRecordingMachine, compact: Bool, caption: String = "left in this block") -> some View {
        if let d = m.display(now: now) {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(d.word).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(d.tone == .work ? SnappetColor.brand : SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.rec.phase")
                    Text(RacketClock.mmss(d.seconds)).font(.system(size: 40, weight: .light)).monospacedDigit()
                        .accessibilityIdentifier("racket.rec.clock")
                    Text(caption).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                RacketTimerRing(display: d, caption: caption)
            }
        }
    }

    /// "Goal: beat 24 shots · Last block 20" (only with a goal or an earlier block).
    @ViewBuilder private func goalPanel(_ m: RacketRecordingMachine, block b: Int) -> some View {
        let measure = ex.drillMeasure
        let goal = RacketDrillGoal.blockLine(RacketDrillDetails(from: ex).goal, measure: measure)
        let lastBlock: String? = {
            guard b > 0, b - 1 < ex.sets.count, let v = RacketDrillHistory.value([ex.sets[b - 1]], measure: measure),
                  measure != .time else { return nil }
            return measure == .madeTried ? "Last block \(v)%" : "Last block \(v)"
        }()
        if goal != nil || lastBlock != nil {
            HStack {
                Text(goal ?? "No goal yet").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let lastBlock { Text(lastBlock).font(.system(size: 14, weight: .semibold)) }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("racket.drill.goal")
        }
    }

    /// Stats: the live-tracking counts (Shots now / Longest, block / Rallies) stay in place as "Not available yet";
    /// blocks done and recorded time are real.
    private func drillStats(_ m: RacketRecordingMachine, block b: Int) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                tile("–", "Shots now")
                tile("–", "Longest, block")
                tile("–", "Rallies")
            }
            Text("Live counts: \(RacketFeatureState.notAvailableYet.label.lowercased()). Log them at the end of the block.")
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.drill.liveCounts")
            HStack(spacing: 10) {
                tile("\(b) of \(blocks)", "Blocks done")
                tile(RacketClock.elapsed(m.log?.recordedSec(now: now) ?? 0), "Recorded")
                tile(heartRate.map { "\(Int($0.rounded()))" } ?? "–", "Heart rate")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("racket.rec.stats")
    }

    private func tile(_ v: String, _ k: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 26, weight: .light)).monospacedDigit()
            Text(k).font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func footnote(_ s: String) -> some View {
        Text(s).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    // MARK: Paused (DrillPaused · XxPaused)

    @ViewBuilder private func pausedScreen(_ m: RacketRecordingMachine, block b: Int) -> some View {
        headerRow(m.recording == .off ? .notRecording : .paused, center: "Block \(b + 1) of \(blocks)", showsPhone: false)
        Spacer(minLength: 0)
        ringOrCompact(m, compact: false, caption: "Block timer stopped")
        Text(RacketDrillCopy.pausedLine(sport)).font(.system(size: 16)).foregroundStyle(SnappetColor.textSecondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("racket.paused.line")
        Button { act { $0.resumeBlock(now: Date()) } } label: {
            Text("Resume").font(.system(size: 20, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(SnappetWidePrimaryStyle())
        .accessibilityIdentifier("racket.paused.resume")
        Text("Or tap Resume on your Watch").font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary)
        Spacer(minLength: 0)
        HStack(spacing: 10) {
            RacketWideButton("End block", id: "racket.paused.endBlock", primary: false) { act { $0.endBlock(now: Date()) } }
            RacketStopButton(title: "Stop drill", id: "racket.paused.stop") { act { $0.end(now: Date()) } }
        }
    }

    // MARK: Rest (RestOff · RestEverything · rest done)

    @ViewBuilder private func restScreen(_ m: RacketRecordingMachine, after a: Int) -> some View {
        let next = a + 2
        let autoStart = m.plan?.autoStart ?? true
        let done = m.phase == .restDone(after: a)
        let everything = m.recording == .everything
        headerRow(everything ? .recordingEverything : status(m), center: "Block \(a + 1) done", showsPhone: false)
        ScrollView {
            VStack(spacing: 10) {
                ringOrCompact(m, compact: false, caption: done ? "Start the next block when you’re ready"
                                                              : RacketDrillCopy.restCaption(next: next, autoStart: autoStart))
                if done {
                    RacketWideButton("Start block \(next)", id: "racket.rec.startBlock") { act { $0.startNextBlock(now: Date()) } }
                } else {
                    HStack(spacing: 8) {
                        RacketWideButton("Pause rest", id: "racket.rec.pauseRest", primary: false) { act { $0.pauseRest(now: Date()); return [] } }
                        RacketWideButton("+30 s", id: "racket.rec.add30", primary: false) { act { $0.addRest(30, now: Date()); return [] } }
                        RacketWideButton("+1 min", id: "racket.rec.add60", primary: false) { act { $0.addRest(60, now: Date()); return [] } }
                    }
                    RacketWideButton("Skip rest, start block \(next)", id: "racket.rec.skipRest") { act { $0.startNextBlock(now: Date()) } }
                }
                if everything {
                    footnote("Rest stays in the recording, marked from your timer, and is left out of your stats.")
                } else {
                    logPanel(after: a)
                    feelRow(after: a)
                    autoStartPanel(m)
                }
                HStack(spacing: 8) {
                    moreOptions(m)
                    Button("Finish drill") { confirmFinish = true }
                        .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("racket.rec.stop")
                }
            }
        }
    }

    // RestPaused (DrillRestPaused · XxRestPaused)
    @ViewBuilder private func restPausedScreen(_ m: RacketRecordingMachine, after a: Int) -> some View {
        let next = a + 2
        headerRow(m.recording == .everything ? .recordingEverything : status(m), center: "Block \(a + 1) done", showsPhone: false)
        Spacer(minLength: 0)
        ringOrCompact(m, compact: false, caption: "Rest timer paused")
        Text("Block \(next) won’t start until you resume. Take your time.").font(.system(size: 16))
            .foregroundStyle(SnappetColor.textSecondary).multilineTextAlignment(.center)
            .accessibilityIdentifier("racket.rest.pausedLine")
        RacketWideButton("Resume rest timer", id: "racket.rec.resumeRest") { act { $0.resumeRest(now: Date()); return [] } }
        HStack(spacing: 8) {
            RacketWideButton("+30 s", id: "racket.rec.add30", primary: false) { act { $0.addRest(30, now: Date()); return [] } }
            RacketWideButton("+1 min", id: "racket.rec.add60", primary: false) { act { $0.addRest(60, now: Date()); return [] } }
        }
        RacketWideButton("Skip rest, start block \(next)", id: "racket.rec.skipRest", primary: false) {
            act { $0.startNextBlock(now: Date()) }
        }
        Spacer(minLength: 0)
        Button("Finish drill") { confirmFinish = true }
            .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("racket.rec.stop")
    }

    private func set(_ i: Int) -> SetLog? { i < ex.sets.count ? ex.sets[i] : nil }

    /// "Longest rally − 14 + · You enter this" (or Made / Tried), "Find rallies after the drill".
    @ViewBuilder private func logPanel(after a: Int) -> some View {
        let measure = ex.drillMeasure
        if measure != .time {
            VStack(spacing: 8) {
                Text(measure == .longestRally ? "Longest rally" : "Made / tried")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                if findAfter.contains(a) {
                    Text(RacketDrillCopy.findAfterLine).font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.rest.findAfterLine")
                } else if measure == .longestRally {
                    stepper(value: set(a)?.longestRally ?? 0, id: "racket.rest.rally") { v in onEditBlock(a) { $0.longestRally = v } }
                } else {
                    HStack(spacing: 10) {
                        stepper(value: set(a)?.drillMade ?? 0, id: "racket.rest.made", label: "Made") { v in
                            onEditBlock(a) { $0.drillMade = v }
                        }
                        stepper(value: set(a)?.drillTried ?? 0, id: "racket.rest.tried", label: "Tried") { v in
                            onEditBlock(a) { $0.drillTried = v }
                        }
                    }
                }
                Text(RacketDrillCopy.logSource(scanFound: false)).font(.system(size: 12))
                    .foregroundStyle(SnappetColor.textSecondary).accessibilityIdentifier("racket.rest.source")
                if filming {
                    Button(findAfter.contains(a) ? "Enter it now instead" : "Find rallies after the drill") {
                        if findAfter.contains(a) { findAfter.remove(a) } else {
                            findAfter.insert(a)
                            onEditBlock(a) { $0.longestRally = nil; $0.drillMade = nil; $0.drillTried = nil }
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("racket.rest.findAfter")
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func stepper(value: Int, id: String, label: String? = nil, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            stepButton("−", id: "\(id).minus") { set(max(0, value - 1)) }
            VStack(spacing: 0) {
                if let label { Text(label).font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary) }
                Text("\(value)").font(.system(size: 36, weight: .light)).monospacedDigit()
                    .accessibilityIdentifier(id)
            }
            .frame(maxWidth: .infinity)
            stepButton("+", id: "\(id).plus") { set(value + 1) }
        }
    }

    private func stepButton(_ s: String, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(s).font(.system(size: 22, weight: .semibold)).frame(width: 56, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func feelRow(after a: Int) -> some View {
        RacketChips(options: RacketDrillFeel.allCases, label: { $0.label },
                    selection: Binding(get: { set(a)?.drillFeel ?? .aboutRight },
                                       set: { f in onEditBlock(a) { $0.drillFeelRaw = f.rawValue } }),
                    idPrefix: "racket.rest.feel", idFor: { $0.rawValue })
    }

    private func autoStartPanel(_ m: RacketRecordingMachine) -> some View {
        RacketBox {
            Toggle(isOn: Binding(get: { m.plan?.autoStart ?? true },
                                 set: { on in act { $0.setAutoStart(on, now: Date()); return [] } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-start").font(.system(size: 15, weight: .semibold))
                    Text("Off: you start the next block yourself").font(SnappetType.detail)
                        .foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .tint(SnappetColor.brand)
            .accessibilityIdentifier("racket.rest.autoStart")
        }
    }

    /// More options: rest length, auto-start, add a block, end after the next one.
    private func moreOptions(_ m: RacketRecordingMachine) -> some View {
        Menu {
            Menu("Rest length") {
                ForEach(RacketRecordingDefaults.restOptions, id: \.self) { sec in
                    Button(RacketClock.mmss(TimeInterval(sec)) + (m.plan?.restSec == sec ? " ✓" : "")) {
                        act { $0.setRestSec(sec, now: Date()); return [] }
                    }
                }
            }
            Button((m.plan?.autoStart ?? true) ? "Turn auto-start off" : "Turn auto-start on") {
                act { $0.setAutoStart(!(m.plan?.autoStart ?? true), now: Date()); return [] }
            }
            Button("Add a block") { act { $0.addBlock(now: Date()); return [] } }
            Button("End after the next block") { act { $0.endAfterNextBlock(now: Date()); return [] } }
                .disabled((m.currentBlock ?? 0) + 2 >= blocks)
        } label: {
            Text("More options").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier("racket.rest.more")
    }

    // MARK: Review

    private var review: some View {
        NavigationStack(path: $reviewPath) {
            RacketDrillReviewScreen(ex: ex, history: history,
                                    onSeeProgress: { reviewPath.append(.trend) },
                                    onDrillVideos: ex.racketRecordingLog == nil ? nil : { videos = RacketVideosTarget(start: .drillVideos(ex.id)) },
                                    onBack: onClose, onDone: onDone)
                .navigationDestination(for: RacketDrillRoute.self) { r in
                    switch r {
                    case .trend: RacketDrillTrendScreen(ex: ex, history: history)
                    }
                }
        }
    }
}

enum RacketDrillRoute: Hashable { case trend }

extension RacketRecordingLog {
    /// The block being filmed at recording time `t`: its index, or nil between blocks.
    func blockIndex(at t: Double) -> Int? {
        marks.last { $0.kind == .block && $0.startSec <= t + 0.5 && ($0.endSec.map { t < $0 } ?? true) }?.index
    }
}

// MARK: - Warm (shared with the drill block)

struct RacketWarmPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("▲ Camera view and live tracking paused").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SnappetColor.perfModerate)
            Text("Your recording is safe and continues. You can still keep score and mark moments.").font(.system(size: 14))
            Text("Shade the phone or take off its case if you can.").font(SnappetType.detail)
                .foregroundStyle(SnappetColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.perfModerate, lineWidth: 1))
        .accessibilityIdentifier("racket.rec.warmPanel")
    }
}

// MARK: - Camera check (CameraCheck → NoModelCamera), shared by match and drill

/// "Cancel · Camera check", the live preview (the cover's persistent one, drawn at this slot) with the court guide,
/// "Line up the view yourself", the amber box, the consent line and Continue.
struct RacketCameraCheckPanel: View {
    let sport: RacketSport
    let fake: Bool
    var videoAspect: CGFloat? = nil
    let accessDenied: Bool
    let continueTitle: String
    var footnote: String? = nil
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel", action: onCancel).accessibilityIdentifier("racket.camera.cancel")
                Spacer()
                Text("Camera check").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Cancel") {}.hidden()
            }
            // The board's media area: full width, 300 tall (CameraCheck / NoModelCamera).
            Color.clear.racketPreviewSlot()
                .overlay {
                    if fake {
                        Text("Camera preview shows here on a device")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                .overlay { RacketCourtGuide(sport: sport, videoAspect: videoAspect) }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("racket.camera.preview")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Line up the view yourself").font(.system(size: 20, weight: .semibold))
                        .accessibilityIdentifier("racket.camera.title")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Automatic court check isn’t available for \(sport.label.lowercased()) yet.")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.perfModerate)
                        Text("Live tracking stays off, so play uses the tracking-off screens.")
                        Text("Place the phone high, side-on or behind, so the whole playing area is in frame.")
                    }
                    .font(SnappetType.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SnappetColor.perfModerate.opacity(0.7), lineWidth: 1))
                    Text("People nearby may be in the video. Check they’re OK with it.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if accessDenied {
                        Text("Snappet needs the camera and your Photos library to record. You can allow them in Settings.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.perfHard)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            RacketWideButton(continueTitle, id: "racket.camera.continue", action: onContinue)
                .disabled(accessDenied)
            if let footnote {
                Text(footnote).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("racket.camera.next")
            }
        }
    }
}

// MARK: - Review (PracticeReview · XxReview)

struct RacketDrillReviewScreen: View {
    let ex: SessionExercise
    let history: [WorkoutSession]
    let onSeeProgress: () -> Void
    /// nil ⇒ no video (Don't film).
    let onDrillVideos: (() -> Void)?
    let onBack: () -> Void
    let onDone: () -> Void

    private var sport: RacketSport { ex.racketSport ?? ex.racketFormat.sport }
    private var name: String { ex.displayName ?? "Drill" }
    private var pastHistory: [WorkoutSession] { history.filter { !$0.exercises.contains { $0.id == ex.id } } }

    var body: some View {
        let measure = ex.drillMeasure
        let r = RacketDrillReview.make(sets: ex.sets, measure: measure,
                                       last: RacketDrillHistory.lastValue(sport: sport, name: name, measure: measure, history: pastHistory),
                                       best: RacketDrillHistory.best(sport: sport, name: name, measure: measure, history: pastHistory),
                                       log: ex.racketRecordingLog)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let tags = RacketDrillDetails(from: ex).tags(sport: sport)
                if !tags.isEmpty {
                    RacketWrapLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { t in
                            Text(t).font(.system(size: 12, weight: .bold)).foregroundStyle(SnappetColor.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SnappetColor.textSecondary))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("racket.review.tags")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(r.headlineTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.textSecondary)
                        Spacer()
                        if r.newBest {
                            Text("▲ New best").font(.system(size: 12, weight: .bold)).foregroundStyle(SnappetColor.perfFresh)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SnappetColor.perfFresh))
                                .accessibilityIdentifier("racket.review.newBest")
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.headline ?? "Not logged").font(.system(size: 32, weight: .light)).monospacedDigit()
                            .accessibilityIdentifier("racket.review.headline")
                        Spacer()
                        if let last = r.lastTime {
                            Text(last).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                                .accessibilityIdentifier("racket.review.lastTime")
                        }
                    }
                    bars(r.bars.map { ($0.label, $0.value, $0.text + ($0.best ? " ▲" : "")) },
                         max: max(1, r.bars.map(\.value).max() ?? 1), id: "racket.review.block")
                    Text("Your confirmed numbers").font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(r.rallies > 0 ? "\(r.rallies) rallies" : "No rallies found yet").font(.system(size: 16, weight: .bold))
                            .accessibilityIdentifier("racket.review.rallies")
                        Spacer()
                        Text(r.blocksLine).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                            .accessibilityIdentifier("racket.review.blocksLine")
                    }
                    if r.rallies > 0 {
                        bars(r.buckets.map { ($0.label, Double($0.count), "\($0.count)") },
                             max: Double(max(1, r.buckets.map(\.count).max() ?? 1)), id: "racket.review.bucket")
                        Text("Estimated from video · lengths in seconds (shot count: not available yet)")
                            .font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                    } else {
                        Text(onDrillVideos == nil ? "Not filmed, so there are no rally lengths."
                                                  : "Find rallies in Drill videos to see how long they were.")
                            .font(.system(size: 12)).foregroundStyle(SnappetColor.textSecondary)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Want more detail?").font(.system(size: 16, weight: .bold))
                Button(action: onDone) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Done for now").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                            Text("Keep your confirmed numbers.").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                        }
                        Spacer()
                        Text("0 min").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                    }
                    .padding(14)
                    .background(SnappetColor.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SnappetColor.brand, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.review.doneForNow")
                // "Tag shot types" — shot tagging isn't built: the tier stays in place, disabled, and says so.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tag shot types").font(.system(size: 15, weight: .semibold))
                        Text("See your forehand and backhand mix.").font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                    }
                    Spacer()
                    Text(RacketFeatureState.notAvailableYet.label).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
                }
                .padding(14)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(0.6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("racket.review.tagShots")
                HStack(spacing: 8) {
                    Button("See progress", action: onSeeProgress)
                        .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("racket.review.progress")
                    if let onDrillVideos {
                        Button("Drill videos", action: onDrillVideos)
                            .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("racket.review.videos")
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Back", action: onBack).accessibilityIdentifier("racket.review.back") }
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone).accessibilityIdentifier("racket.review.done") }
        }
    }

    private func bars(_ rows: [(String, Double, String)], max top: Double, id: String) -> some View {
        VStack(spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { k, row in
                HStack(spacing: 8) {
                    Text(row.0).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary).frame(width: 62, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 4).fill(SnappetColor.brand)
                                .frame(width: max(row.1 > 0 ? 4 : 0, g.size.width * row.1 / top))
                        }
                    }
                    .frame(height: 12)
                    Text(row.2).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(id).\(k)")
            }
        }
    }
}

// MARK: - DrillTrend ("Drill progress")

struct RacketDrillTrendScreen: View {
    let ex: SessionExercise
    let history: [WorkoutSession]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric: RacketDrillTrend.Metric = .measure
    @State private var drawn = false

    private var sport: RacketSport { ex.racketSport ?? ex.racketFormat.sport }
    private var name: String { ex.displayName ?? "Drill" }
    private var past: [WorkoutSession] { history.filter { !$0.exercises.contains { $0.id == ex.id } } }

    private func metricLabel(_ m: RacketDrillTrend.Metric) -> String {
        m == .measure ? ex.drillMeasure.label : "Rallies per block"
    }

    var body: some View {
        let s = RacketDrillTrend.summary(sport: sport, name: name, measure: ex.drillMeasure, metric: metric,
                                         history: past, today: ex, now: Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(metricLabel(metric)).font(.system(size: 22, weight: .bold))
                    Spacer()
                    if s.bestYet {
                        Text("▲ Best yet").font(.system(size: 13, weight: .bold)).foregroundStyle(SnappetColor.perfFresh)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SnappetColor.perfFresh))
                            .accessibilityIdentifier("racket.trend.bestYet")
                    }
                }
                Text(metric == .measure ? "Your confirmed numbers, last \(s.points.count) \(s.points.count == 1 ? "session" : "sessions")"
                                        : "Rallies found on video, last \(s.points.count) \(s.points.count == 1 ? "session" : "sessions")")
                    .font(.system(size: 15)).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.trend.subtitle")
                if s.points.isEmpty {
                    Text(metric == .measure ? "Log a block to start your progress."
                                            : "Find rallies in your drill videos to see rallies per block.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .accessibilityIdentifier("racket.trend.empty")
                } else {
                    chart(s)
                }
                HStack(alignment: .top) {
                    stat(s.best.map(RacketDrillTrend.number) ?? "–", "best")
                    stat(s.average.map(RacketDrillTrend.number) ?? "–", "average, last \(s.points.count)")
                    stat("\(s.sessions)", s.sessions == 1 ? "session" : "sessions")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("racket.trend.stats")
                VStack(alignment: .leading, spacing: 6) {
                    Text("How it felt").font(.system(size: 15, weight: .semibold))
                    Text(RacketDrillTrend.feelLine(sport: sport, name: name, history: past, today: ex)
                         ?? "Rate blocks Easy, About right or Hard during rest to see this.")
                        .font(.system(size: 15))
                        .accessibilityIdentifier("racket.trend.feel")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 8) {
                    ForEach(RacketDrillTrend.Metric.allCases, id: \.self) { m in
                        chip(metricLabel(m), on: metric == m, id: "racket.trend.metric.\(m.rawValue)") {
                            drawn = false
                            metric = m
                            withAnimation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion)) { drawn = true }
                        }
                    }
                    // "Shot mix" needs shot tags, which aren't built: the chip stays, disabled.
                    chip("Shot mix", on: false, id: "racket.trend.metric.shotMix") {}
                        .disabled(true).opacity(0.45)
                        .accessibilityHint(RacketFeatureState.notAvailableYet.label)
                }
            }
            .padding(16)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion)) { drawn = true }
        }
    }

    /// The board's bar chart: one bar per session, today in the accent, earlier sessions in a quieter accent, the value
    /// on top, dates underneath, no y-axis (the repo's grow-on-appear BarMark pattern).
    private func chart(_ s: RacketDrillTrend.Summary) -> some View {
        Chart(s.points) { p in
            BarMark(x: .value("Session", p.label), y: .value(metricLabel(metric), drawn || reduceMotion ? p.value : 0),
                    width: s.points.count >= 4 ? .ratio(0.78) : .fixed(64))
                .foregroundStyle(p.isToday ? SnappetColor.brand : SnappetColor.brand.opacity(0.45))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 4) {
                    Text(RacketDrillTrend.number(p.value)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                }
                .accessibilityLabel(p.label)
                .accessibilityValue(RacketDrillTrend.number(p.value))
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary) }
        }
        .chartYScale(domain: 0...max(1, (s.points.map(\.value).max() ?? 1) * 1.18))
        .frame(height: 200)
        .accessibilityIdentifier("racket.trend.chart")
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 26, weight: .light)).monospacedDigit()
            Text(k).font(.system(size: 13)).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ label: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { action(); Haptics.tap() } label: {
            Text(label).font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? SnappetColor.brand : SnappetColor.ink)
                .padding(.horizontal, 10).frame(minHeight: 40)
                .background(on ? SnappetColor.brand.opacity(0.14) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? SnappetColor.brand : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Court diagram (Customize "Pattern": From / To)

/// The boards' table / court from above: a 6 × 3 grid with a net line. Tap a zone for From, another for To; a third
/// tap starts again. Pure choice rule: `RacketCourtZoneRule`.
struct RacketCourtZones: View {
    let sport: RacketSport
    @Binding var from: Int?
    @Binding var to: Int?

    private var fill: Color {
        switch sport {
        case .tableTennis: return Color(red: 0x1D / 255, green: 0x4C / 255, blue: 0x7E / 255)
        case .badminton: return Color(red: 0x20 / 255, green: 0x50 / 255, blue: 0x3F / 255)
        case .tennis: return Color(red: 0x2B / 255, green: 0x5C / 255, blue: 0x8A / 255)
        case .pickleball: return Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0x5A / 255)
        case .padel: return Color(red: 0x28 / 255, green: 0x5A / 255, blue: 0x8C / 255)
        case .squash: return Color(red: 0x6B / 255, green: 0x52 / 255, blue: 0x30 / 255)
        }
    }

    var body: some View {
        let cols = RacketDrillChoices.columns, rows = RacketDrillChoices.rows
        VStack(spacing: 3) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<cols, id: \.self) { c in
                        let z = r * cols + c
                        Button {
                            (from, to) = RacketCourtZoneRule.tap(z, from: from, to: to)
                            Haptics.tap()
                        } label: {
                            Text(z == from ? "From" : z == to ? "To" : "")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(z == from || z == to ? SnappetColor.brand.opacity(0.3) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(z == from || z == to ? SnappetColor.brand : Color.white.opacity(0.35), lineWidth: 1.2))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("racket.custom.zone.\(z)")
                        .accessibilityLabel(z == from ? "From" : z == to ? "To" : "Zone \(z + 1)")
                        if c == cols / 2 - 1 { Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2) }
                    }
                }
            }
        }
        .padding(6)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sport == .tableTennis ? "Table from above" : "Court from above")
        .accessibilityIdentifier("racket.custom.court")
    }
}
