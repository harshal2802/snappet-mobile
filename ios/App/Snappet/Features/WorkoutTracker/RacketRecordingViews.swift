import SwiftUI
import AVFoundation

// MARK: - Racket recording screens (prompt 244, issue #438 step 1)
//
// The recording choice in setup, Settings → Racket recording, the storage check, and the record-everything screen
// (a whole match, or a drill's countdown → block → rest → review) with its interruption and "Still playing?"
// panels. Thin renderers over the pure `RacketRecordingMachine` (`RacketRecording.swift`); the camera and Photos
// live in `Services/RacketRecorder.swift`. Boards: TtSetupFirst / PracticeSetup, TtStorage, TtRecordAll,
// DrillCountdown (BlockStart), TtBlockAll, TtRestEverything, TtInterrupted, TtInterruptedStop, StillPlaying,
// *Settings ("Recording defaults").

// MARK: - Recording choice (setup)

/// The three recording choices as full-width rows (no segmented control: the labels must never truncate), with
/// the chosen one's helper line under them.
struct RacketRecordingChoice: View {
    @Binding var selection: RacketRecordingMode
    let mode: RacketMode
    var unit: RacketUnit = .game

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(RacketRecordingMode.allCases, id: \.self) { m in
                Button { selection = m; Haptics.tap() } label: {
                    HStack(spacing: 10) {
                        Text(m.label(for: mode, unit: unit))
                            .font(.system(size: 15, weight: selection == m ? .semibold : .regular))
                            .foregroundStyle(SnappetColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if selection == m {
                            // Selection is the `.isSelected` trait; the mark stays out of the button's label.
                            Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(SnappetColor.brand)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("racket.recording.\(m.rawValue)")
                .accessibilityAddTraits(selection == m ? .isSelected : [])
            }
            Text(selection.helper(for: mode, unit: unit))
                .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("racket.recording.helper")
        }
    }
}

// MARK: - Settings → Racket recording ("Recording defaults")

struct RacketRecordingSettingsView: View {
    @AppStorage(RacketRecordingDefaults.storageKey) private var data = Data()

    private var defaults: Binding<RacketRecordingDefaults> {
        Binding(get: { RacketRecordingDefaults.load(from: data) },
                set: { data = $0.encoded ?? Data() })
    }

    var body: some View {
        Form {
            Section {
                Picker("Matches start as", selection: defaults.matchMode) {
                    ForEach(RacketRecordingMode.allCases, id: \.self) { Text($0.label(for: .match)).tag($0) }
                }
                .accessibilityIdentifier("racketSettings.matchMode")
                Picker("Drills start as", selection: defaults.drillMode) {
                    ForEach(RacketRecordingMode.allCases, id: \.self) { Text($0.label(for: .drill)).tag($0) }
                }
                .accessibilityIdentifier("racketSettings.drillMode")
                Picker("Quality", selection: defaults.quality) {
                    ForEach(RacketRecordingQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("racketSettings.quality")
            } header: {
                Text("Recording defaults")
            } footer: {
                Text("Applies to all racket sports. You can still change it for any match or drill. Recordings save to your Photos library.")
            }

            Section {
                Picker("Rest time", selection: defaults.restSec) {
                    ForEach(RacketRecordingDefaults.restOptions, id: \.self) { Text(RacketClock.mmss(TimeInterval($0))).tag($0) }
                }
                .accessibilityIdentifier("racketSettings.rest")
                Toggle("Start next block automatically", isOn: defaults.autoStartNextBlock)
                    .accessibilityIdentifier("racketSettings.autoStart")
                Picker("Countdown before a block", selection: defaults.countdownSec) {
                    ForEach(RacketRecordingDefaults.countdownOptions, id: \.self) { Text("\($0) s").tag($0) }
                }
                .accessibilityIdentifier("racketSettings.countdown")
            } header: {
                Text("Between drill blocks")
            } footer: {
                Text("With auto-start on, the next block counts down when the rest timer ends.")
            }

            Section {
                Picker("Game by game", selection: defaults.stillPlayingByUnitMin) {
                    ForEach(RacketRecordingDefaults.stillByUnitOptions, id: \.self) { Text("\($0) min").tag(Int?.some($0)) }
                    Text("Off").tag(Int?.none)
                }
                .accessibilityIdentifier("racketSettings.stillByUnit")
                Picker("Record everything", selection: defaults.stillPlayingEverythingMin) {
                    ForEach(RacketRecordingDefaults.stillEverythingOptions, id: \.self) { Text("\($0) min").tag(Int?.some($0)) }
                    Text("Off").tag(Int?.none)
                }
                .accessibilityIdentifier("racketSettings.stillEverything")
            } header: {
                Text("Still playing check")
            } footer: {
                Text("Asks when there are no score taps or marks for this long. With no answer, recording stops 2 minutes later and everything so far stays saved.")
            }
        }
        .navigationTitle("Racket recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage check (TtStorage)

struct RacketStorageSheet: View {
    let mode: RacketMode
    let defaultQuality: RacketRecordingQuality
    let onContinue: (RacketRecordingQuality) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quality: RacketRecordingQuality = .hd1080
    @State private var storage: (free: Int64, total: Int64)?
    @State private var denied = false
    @State private var asking = false
    @State private var configured = false

    /// The simulator reports the Mac's disk; a missing reading is treated as plenty (the edge still stops on full).
    private var free: Int64 { storage?.free ?? 64_000_000_000 }
    private func config(_ q: RacketRecordingQuality) -> RacketCaptureConfig { RacketCaptureConfig(quality: q) }
    private var verdict: RacketStorageCheck.Verdict { RacketStorageCheck.verdict(freeBytes: free, config: config(quality)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Record everything · for this match or drill").snappetLabel()
                        Text(RacketStorageCheck.roomLine(freeBytes: free, config: config(quality)))
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(verdictColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.storage.room")
                        Text("Saved to your Photos library. Recording everything keeps breaks too, so it uses more space.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let storage {
                        HStack {
                            Text("\(RacketStorageCheck.gigabytes(storage.free)) free")
                            Spacer()
                            if storage.total > 0 { Text(RacketStorageCheck.gigabytes(storage.total)).foregroundStyle(SnappetColor.textSecondary) }
                        }
                        .font(SnappetType.body.monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recording quality").snappetLabel().padding(.bottom, 6)
                        ForEach(RacketRecordingQuality.allCases, id: \.self) { q in
                            Button { quality = q; Haptics.tap() } label: {
                                HStack {
                                    Text(q.label).font(.system(size: 15, weight: quality == q ? .semibold : .regular))
                                    Spacer()
                                    Text(qualityLine(q))
                                        .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                                    if quality == q {
                                        Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(SnappetColor.brand)
                                    }
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("racket.storage.quality.\(q.rawValue)")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .pagerGlass(cornerRadius: 18)
                    Text("Saved in 10-minute parts as it records, so a crash or full storage loses minutes, not the whole recording.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if denied {
                        Text("Snappet needs the camera and your Photos library to record. You can allow them in Settings.")
                            .font(SnappetType.detail).foregroundStyle(SnappetColor.perfHard)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("racket.storage.denied")
                    }
                    Button {
                        asking = true
                        Task {
                            let ok = await RacketRecorder.requestAccess()
                            asking = false
                            guard ok else { denied = true; return }
                            dismiss()
                            onContinue(quality)
                        }
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .disabled(verdict == .notEnough || asking)
                    .accessibilityIdentifier("racket.storage.continue")
                    Text("A match starts recording now. A drill checks the camera first.")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .navigationTitle("Check space first")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("racket.storage.cancel")
                }
            }
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            quality = defaultQuality
            storage = RacketRecorder.storage()
        }
    }

    /// "About 1 h 50 min", "About 5 h · tracking still works" (TtStorage).
    private func qualityLine(_ q: RacketRecordingQuality) -> String {
        let room = RacketStorageCheck.roughDuration(RacketStorageCheck.roomSec(freeBytes: free, config: config(q)))
        return q == .hd1080 ? "About \(room) · tracking still works" : "About \(room)"
    }

    private var verdictColor: Color {
        switch verdict {
        case .plenty: return SnappetColor.ink
        case .tight: return SnappetColor.perfModerate
        case .notEnough: return SnappetColor.perfHard
        }
    }
}

// MARK: - Timer ring

/// The phase ring: Work in the accent, Rest in grey (paused at 0.55), Done in green. The word sits above light
/// numerals, so the phase reads in the word and the ring.
struct RacketTimerRing: View {
    let display: RacketTimerDisplay
    var caption: String? = nil

    private var color: Color {
        switch display.tone {
        case .work: return SnappetColor.brand
        case .rest: return SnappetColor.textSecondary
        case .restPaused: return SnappetColor.textSecondary.opacity(0.55)
        case .done: return SnappetColor.perfFresh
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(SnappetColor.hairline, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, display.progress)))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: display.progress)
            VStack(spacing: 2) {
                Text(display.word)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .accessibilityIdentifier("racket.rec.phase")
                Text(RacketClock.mmss(display.seconds))
                    .font(.system(size: 56, weight: .light)).monospacedDigit()
                    .foregroundStyle(SnappetColor.ink)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("racket.rec.clock")
                if let caption {
                    Text(caption).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .padding(24)
        }
        .frame(width: 240, height: 240)
    }
}

// MARK: - Record everything (RecordAll · BlockStart · BlockAll · RestEverything · Review)

/// The storage check's presentation: which match / drill is about to record everything.
struct RacketStorageTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
    let mode: RacketMode
}

/// What the host presents: the match / drill being recorded and the quality chosen in the storage check.
struct RacketRecordingTarget: Identifiable {
    let id = UUID()
    let exerciseID: UUID
    let quality: RacketRecordingQuality
}

struct RacketRecordingCover: View {
    /// The match / drill, live from the host (its score and blocks update as they're logged).
    let ex: SessionExercise
    let quality: RacketRecordingQuality
    let defaults: RacketRecordingDefaults
    /// A Photos part was saved: attach it to the entity.
    let onPartSaved: (RecordedClip) -> Void
    /// The recording log changed: persist it on the entity.
    let onLog: (RacketRecordingLog) -> Void
    /// A drill block finished (index, seconds): log it.
    let onBlockLogged: (Int, TimeInterval) -> Void
    /// End routed to "confirm the score" (game by game).
    let onScore: () -> Void
    /// After a whole-match recording: a game's score entered (log, set index).
    let onSaveScore: (SetLog, Int) -> Void
    /// …or left for later ("Score unconfirmed").
    let onScoreLater: () -> Void
    /// A game / set tallied point by point on the Apple Watch finished: log it "from Watch" (prompt 245).
    var onWatchUnit: (SetLog) -> Void = { _ in }
    let onClose: () -> Void

    private enum Show: String { case dim, camera }

    @State private var recorder = RacketRecorder()
    @State private var machine: RacketRecordingMachine?
    @State private var now = Date()
    @State private var show: Show = .dim
    @State private var confirmStop = false
    @State private var idleTimerWas = false
    @State private var storageFree: Int64?
    /// Measured write rate + live free space (sampled every 5 s) for "space left".
    @State private var meter = RacketWriteRateMeter()
    @State private var ticks = 0
    /// Games already logged when the recording began; the scores step asks for the ones after.
    @State private var baseSets = 0
    @State private var gamesToScore: Int?
    @State private var scoreTarget: RacketScoreTarget?
    /// The Watch's point tally for the game being played (a match recording everything, prompt 245).
    @State private var liveScore: RacketLiveScore?
    /// Units the Watch logged during this recording (the next one's rules — a super tiebreak — follow from it).
    @State private var watchUnitsLogged = 0

    private var unit: RacketUnit { ex.racketFormat.sport.unit }
    private var title: String { ex.isRacketMatch ? ex.racketMatchTitle : (ex.displayName ?? "Drill") }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 14) {
                topBar
                if let m = machine { content(m) } else { Spacer() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let m = machine, let reason = m.interruption {
                overlayPanel { interruptedPanel(m, reason) }
            } else if let m = machine, m.stillPlayingAskedAt != nil {
                overlayPanel { stillPlayingPanel(m) }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear(perform: setUp)
        .onDisappear {
            recorder.stopPreview()
            UIApplication.shared.isIdleTimerDisabled = idleTimerWas
            RacketWatchRelay.shared.detach(ex.id)
        }
        // The Watch mirrors this screen (prompt 245): every change of what it should show is sent.
        .onChange(of: watchState) { _, s in if let s { RacketWatchRelay.shared.publish(s) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
                act { $0.tick(now: now) }
                ticks += 1
                if ticks % 10 == 0 { sampleStorage() }
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button(ex.isRacketMatch ? "Stop and split" : "Finish drill", role: .destructive) { act { $0.end(now: Date()) } }
                .accessibilityIdentifier("racket.rec.confirmStop")
        } message: {
            Text("Everything so far is saved in your Photos library.")
        }
        .sheet(item: $scoreTarget) { t in
            RacketScoreSheet(ex: ex, unitIndex: t.unitIndex, durationSec: nil) { log in onSaveScore(log, t.unitIndex) }
        }
    }

    /// The config the camera writes, and "space left" from the measured rate once it has warmed up.
    private var captureConfig: RacketCaptureConfig { RacketCaptureConfig(quality: quality, codec: recorder.codec) }
    private var spaceLeftSec: TimeInterval? {
        guard let free = storageFree else { return nil }
        let rate = meter.effectiveRate(estimate: RacketBitrate.bytesPerSecond(captureConfig))
        return RacketStorageCheck.roomSec(freeBytes: free, bytesPerSec: rate)
    }

    private func sampleStorage() {
        if recorder.isCapturing, let bytes = recorder.bytesWritten {
            meter.sample(at: Date(), totalBytes: bytes)
        } else {
            meter.pause()
        }
        storageFree = RacketRecorder.storage()?.free ?? storageFree
    }

    // MARK: Set-up + plumbing

    private func setUp() {
        guard machine == nil else { return }
        idleTimerWas = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true   // a propped phone must not lock mid-match
        storageFree = RacketRecorder.storage()?.free
        baseSets = ex.sets.count
        let kind: RacketRecordingMachine.Kind = ex.isRacketDrill
            ? .drill(RacketDrillPlan(from: ex, defaults: defaults)) : .match
        var m = RacketRecordingMachine(kind: kind, recording: .everything,
                                       stillPlayingMinutes: defaults.stillPlayingMinutes(for: .everything), now: Date())
        recorder.onPartSaved = { clip in
            onPartSaved(clip)
            act { m in
                m.assetSaved(localIdentifier: clip.localIdentifier, startedAt: clip.capturedAt, durationSec: clip.durationSec)
                return []
            }
        }
        recorder.onInterrupted = { reason in
            act { m in m.interrupt(reason, now: Date()); return [] }
            Haptics.warning()
        }
        recorder.startPreview(quality: quality)
        if ex.isRacketMatch { liveScore = RacketLiveScore(rules: watchRules(unitIndex: baseSets)) }
        RacketWatchRelay.shared.attach(ex.id) { command, now in handleWatch(command, now: now) }
        // "A match starts recording now"; a drill waits on the camera for "Start block 1".
        let effects = ex.isRacketMatch ? m.start(now: Date()) : []
        machine = m
        if ex.isRacketDrill { show = .camera }
        perform(effects)
        if let log = m.log { onLog(log) }
        if let s = watchState { RacketWatchRelay.shared.publish(s) }
    }

    // MARK: The Watch (prompt 245)

    private func watchRules(unitIndex: Int) -> RacketLiveRules {
        RacketLiveRules(format: ex.racketFormat, unitIndex: unitIndex)
    }

    /// What the Watch shows for this screen, from the live entity (its unit number and match line).
    private var watchState: RacketWatchState? {
        guard let m = machine else { return nil }
        let score = liveScore ?? RacketLiveScore(rules: watchRules(unitIndex: ex.sets.count))
        return RacketWatchBridge.coverState(m, context: RacketWatchContext(ex), score: score, now: now)
    }

    /// A tap on the Watch. It counts as activity for "Still playing?" (the bridge notes it on the machine).
    private func handleWatch(_ command: RacketWatchCommand, now: Date) {
        guard var m = machine else { return }
        let before = m.log
        var score = liveScore ?? RacketLiveScore(rules: watchRules(unitIndex: baseSets + watchUnitsLogged))
        let out = RacketWatchBridge.apply(command, to: &m, score: &score, now: now)
        machine = m
        if let result = out.unitFinished {
            onWatchUnit(SetLog(watchResult: result, durationSec: nil))
            watchUnitsLogged += 1
            score = RacketLiveScore(rules: watchRules(unitIndex: baseSets + watchUnitsLogged))
        } else if out.resetScore {
            score = RacketLiveScore(rules: watchRules(unitIndex: baseSets + watchUnitsLogged))
        }
        if m.racketMode == .match { liveScore = score }
        perform(out.effects)
        if m.log != before, let log = m.log { onLog(log) }
    }

    /// Run one event on the machine, then its effects; persist the log when it changed.
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
            case .ended(let route):
                Haptics.success()
                if route == .score { onScore(); onClose() }
            case .continueWithoutVideo: onClose()
            }
        }
    }

    // MARK: Chrome

    @ViewBuilder private var background: some View {
        if show == .camera {
            RacketCameraPreview(session: recorder.session, fake: recorder.fake).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.15), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            statusPill
            Spacer(minLength: 4)
            Picker("Show", selection: $show) {
                Text("Dim").tag(Show.dim)
                Text("Camera").tag(Show.camera)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("racket.rec.show")
        }
    }

    @ViewBuilder private var statusPill: some View {
        let m = machine
        let recorded = m?.log?.recordedSec(now: now) ?? 0
        Group {
            if m?.isEnded == true {
                Label("Recording saved", systemImage: "checkmark.circle.fill").foregroundStyle(SnappetColor.perfFresh)
            } else if let i = m?.interruption {
                Text(i.canResume ? "Ⅱ Recording stopped" : "■ Recording ended").foregroundStyle(SnappetColor.perfModerate)
            } else if m?.capturing == true {
                HStack(spacing: 6) {
                    Circle().fill(SnappetColor.perfHard).frame(width: 8, height: 8)
                    Text("Recording \(RacketClock.elapsed(recorded))").monospacedDigit()
                }
            } else {
                Text("Not recording yet").foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .accessibilityIdentifier("racket.rec.status")
    }

    private func overlayPanel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(20)
                .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(20)
        }
    }

    // MARK: Content by phase

    @ViewBuilder private func content(_ m: RacketRecordingMachine) -> some View {
        switch m.phase {
        case .recordingMatch: matchPanel(m)
        case .ready: readyPanel(m)
        case .countdown(let b, let endsAt): countdownPanel(m, block: b, endsAt: endsAt)
        case .block(let b, _): blockPanel(m, block: b)
        case .rest(let a, _), .restPaused(let a, _), .restDone(let a): restPanel(m, after: a)
        case .ended(let route): endPanel(m, route)
        }
    }

    private func header(_ label: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).snappetLabel()
            Text(title).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stopButton(_ label: String) -> some View {
        Button { confirmStop = true } label: {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay(Capsule().strokeBorder(SnappetColor.perfHard, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.rec.stop")
    }

    private func secondary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .pagerOutline()
        .accessibilityIdentifier(id)
    }

    private func primary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).frame(maxWidth: .infinity, minHeight: 30) }
            .buttonStyle(SnappetWidePrimaryStyle())
            .accessibilityIdentifier(id)
    }

    // RecordAll
    private func matchPanel(_ m: RacketRecordingMachine) -> some View {
        let state = ex.racketState
        let room = spaceLeftSec
        return VStack(spacing: 14) {
            header("Match, everything", title)
            Text(savedLine).font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("racket.rec.saved")
            Text("\(state.won) – \(state.lost)")
                .font(.system(size: 64, weight: .light)).monospacedDigit()
                .accessibilityIdentifier("racket.rec.score")
            if let live = liveScore, !live.isEmpty {
                // TtRecordAll: "Score from Watch" — the point tally of the game being played.
                Text("\(live.header(unitNumber: ex.sets.count + 1)) · \(live.display) · score from Watch")
                    .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("racket.rec.watchScore")
            }
            HStack(spacing: 10) {
                stat("Marks", "\(m.log?.userMarkCount ?? 0)")
                stat("Space left, \(quality.label)", room.map(RacketStorageCheck.roughDuration) ?? "Unknown")
                    .accessibilityIdentifier("racket.rec.space")
                    .accessibilityHint(meter.isMeasured ? "Measured from what's been recorded" : "Estimated from the camera settings")
            }
            primary("Mark this moment", id: "racket.rec.mark") { act { $0.mark(.moment, now: Date()); return [] }; Haptics.tap() }
            secondary("New \(unit.noun) starts", id: "racket.rec.newGame") {
                act { $0.mark(.newGame, now: Date()); return [] }
                if liveScore != nil { liveScore = RacketLiveScore(rules: watchRules(unitIndex: baseSets + watchUnitsLogged)) }
                Haptics.tap()
            }
            footnote(RacketStillPlaying.recordAllFooter(minutes: defaults.stillPlayingEverythingMin))
            Spacer(minLength: 0)
            stopButton("Stop and split")
        }
    }

    private var savedLine: String {
        if recorder.savingParts > 0 { return "Saving a part to Photos…" }
        guard let at = recorder.lastSavedAt else { return "Saves to Photos every 10 minutes" }
        let min = Int(now.timeIntervalSince(at) / 60)
        return min < 1 ? "Saved just now" : "Saved \(min) min ago"
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).snappetLabel().fixedSize(horizontal: false, vertical: true)
            Text(v).font(.system(size: 20, weight: .light)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .pagerGlass(cornerRadius: 16)
    }

    private func blocksLabel(_ b: Int, _ m: RacketRecordingMachine) -> String {
        "Block \(b + 1) of \(m.plan?.blocks ?? 1)"
    }

    // Before block 1 (and after Wait): the camera, then Start.
    private func readyPanel(_ m: RacketRecordingMachine) -> some View {
        VStack(spacing: 14) {
            header("Drill, everything · \(blocksLabel(0, m))", title)
            footnote("Point the camera at the play. Recording and the block timer start at zero, after a \(m.plan?.countdownSec ?? 5) s countdown.")
            Spacer()
            primary("Start block 1", id: "racket.rec.startBlock") { act { $0.startNextBlock(now: Date()) } }
            secondary("Back to the drill", id: "racket.rec.back") { onClose() }
        }
    }

    // BlockStart (review5 M3: block 1 has its own copy; Wait never leads to a rest timer before block 1)
    private func countdownPanel(_ m: RacketRecordingMachine, block b: Int, endsAt: Date) -> some View {
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        return VStack(spacing: 14) {
            header("Starting soon", blocksLabel(b, m))
            Spacer()
            Text("\(left)")
                .font(.system(size: 120, weight: .light)).monospacedDigit()
                .foregroundStyle(SnappetColor.brand)
                .contentTransition(.numericText())
                .accessibilityIdentifier("racket.rec.countdown")
            footnote(b == 0 ? "Recording and the block timer start at zero."
                            : "Still recording. The block timer starts at zero.")
            Spacer()
            HStack(spacing: 10) {
                secondary("Wait", id: "racket.rec.wait") { act { $0.wait(now: Date()); return [] } }
                secondary("+30 s", id: "racket.rec.addCountdown") { act { $0.extendCountdown(by: 30, now: Date()); return [] } }
            }
            footnote(b == 0 ? "Wait goes back to the camera." : "Wait returns to a paused rest timer.")
        }
    }

    // BlockAll
    private func blockPanel(_ m: RacketRecordingMachine, block b: Int) -> some View {
        VStack(spacing: 14) {
            header("Block, recording everything", blocksLabel(b, m))
            if let d = m.display(now: now) { RacketTimerRing(display: d, caption: "left in this block") }
            footnote("Blocks and rests are marked from your timers, so there’s nothing to split by hand.")
            Spacer(minLength: 0)
            primary("End block", id: "racket.rec.endBlock") { act { $0.endBlock(now: Date()) } }
        }
    }

    // RestEverything (+ paused / done)
    @ViewBuilder private func restPanel(_ m: RacketRecordingMachine, after a: Int) -> some View {
        let next = a + 2
        let autoStart = m.plan?.autoStart ?? true
        VStack(spacing: 14) {
            header("Rest, recording continues", "Block \(a + 1) done")
            if let d = m.display(now: now) { RacketTimerRing(display: d) }
            switch m.phase {
            case .rest:
                footnote(autoStart ? "Block \(next) starts by itself after this" : "Auto-start is off: you start the next block yourself")
                HStack(spacing: 8) {
                    secondary("Pause rest", id: "racket.rec.pauseRest") { act { $0.pauseRest(now: Date()); return [] } }
                    secondary("+30 s", id: "racket.rec.add30") { act { $0.addRest(30, now: Date()); return [] } }
                    secondary("+1 min", id: "racket.rec.add60") { act { $0.addRest(60, now: Date()); return [] } }
                }
                primary("Skip rest, start block \(next)", id: "racket.rec.skipRest") { act { $0.startNextBlock(now: Date()) } }
            case .restPaused:
                footnote("Rest timer paused. Block \(next) won’t start until you resume. Take your time.")
                HStack(spacing: 8) {
                    secondary("+30 s", id: "racket.rec.add30") { act { $0.addRest(30, now: Date()); return [] } }
                    secondary("+1 min", id: "racket.rec.add60") { act { $0.addRest(60, now: Date()); return [] } }
                }
                primary("Resume rest timer", id: "racket.rec.resumeRest") { act { $0.resumeRest(now: Date()); return [] } }
                secondary("Skip rest, start block \(next)", id: "racket.rec.skipRest") { act { $0.startNextBlock(now: Date()) } }
            default:
                primary("Start block \(next)", id: "racket.rec.startBlock") { act { $0.startNextBlock(now: Date()) } }
            }
            footnote("Rest stays in the recording, marked from your timer, and is left out of your stats.")
            Spacer(minLength: 0)
            stopButton("Finish drill")
        }
    }

    // SplitPrompt placeholder (match) · drill Review
    @ViewBuilder private func endPanel(_ m: RacketRecordingMachine, _ route: RacketRecordingEndRoute) -> some View {
        let recorded = m.log?.recordedSec(now: now) ?? 0
        VStack(spacing: 14) {
            if route == .drillReview {
                header("Drill done", title)
                if let d = m.display(now: now) { RacketTimerRing(display: d, caption: "recorded") }
                Text(m.log?.drillSummaryLine ?? "1 recording")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityIdentifier("racket.rec.summary")
                footnote("Each block is a time range on the one recording, so there’s nothing to split. The recording stays in your Photos library; a drill never offers to delete it.")
            } else {
                header("Recording saved", title)
                Text(RacketClock.elapsed(recorded))
                    .font(.system(size: 56, weight: .light)).monospacedDigit()
                    .accessibilityIdentifier("racket.rec.recorded")
                Text("recorded · \(m.log?.userMarkCount ?? 0) marks").snappetLabel()
                scoresStep(m)
                footnote("You can split it any time from Your videos. The original is never changed.")
            }
            if recorder.savingParts > 0 {
                Label("Saving to Photos…", systemImage: "arrow.down.circle").font(SnappetType.detail)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer(minLength: 0)
            primary("Done", id: "racket.rec.done") {
                // Games not scored yet are kept for later, as "Score unconfirmed".
                if route == .splitPrompt { for _ in 0..<pendingGames(m) { onScoreLater() } }
                onClose()
            }
        }
    }

    // MARK: Scores after a whole-match recording (Skip = later → "Score unconfirmed", review5 M5)

    private func gameCount(_ m: RacketRecordingMachine) -> Int {
        gamesToScore ?? m.log?.suggestedGameCount(
            maxRemaining: RacketRecordedGames.maxRemaining(format: ex.racketFormat, loggedUnits: baseSets)) ?? 1
    }

    /// Recorded games with no entry yet (none once the match is decided).
    private func pendingGames(_ m: RacketRecordingMachine) -> Int {
        ex.racketState.isDecided ? 0 : max(0, gameCount(m) - (ex.sets.count - baseSets))
    }

    @ViewBuilder private func scoresStep(_ m: RacketRecordingMachine) -> some View {
        let count = gameCount(m)
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: Binding(get: { count }, set: { gamesToScore = max(1, $0) }), in: 1...30) {
                Text("\(count) \(count == 1 ? unit.noun : "\(unit.noun)s") recorded").font(.system(size: 15, weight: .semibold))
            }
            .accessibilityIdentifier("racket.scores.count")
            ForEach(0..<count, id: \.self) { k in scoreRow(setIndex: baseSets + k) }
        }
        .padding(14)
        .pagerGlass(cornerRadius: 18)
    }

    @ViewBuilder private func scoreRow(setIndex i: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(unit.noun.capitalized) \(i + 1)").font(SnappetType.body)
            Spacer(minLength: 4)
            if i < ex.sets.count {
                let state = ex.sets[i].racketScoreState
                Text(state?.label ?? "—")
                    .font(SnappetType.detail.monospacedDigit())
                    .foregroundStyle(state?.needsConfirming == true ? SnappetColor.perfModerate : SnappetColor.ink)
                    .accessibilityIdentifier("racket.scores.state.\(i)")
                if state?.needsConfirming == true {
                    Button("Confirm") { scoreTarget = RacketScoreTarget(exerciseID: ex.id, unitIndex: i, durationSec: nil) }
                        .font(SnappetType.detail.weight(.semibold))
                        .accessibilityIdentifier("racket.scores.confirm.\(i)")
                }
            } else if i == ex.sets.count && !ex.racketState.isDecided {
                Button("Later") { onScoreLater(); Haptics.tap() }
                    .font(SnappetType.detail.weight(.semibold)).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.scores.later")
                Button("Enter score") { scoreTarget = RacketScoreTarget(exerciseID: ex.id, unitIndex: i, durationSec: nil) }
                    .font(SnappetType.detail.weight(.semibold))
                    .accessibilityIdentifier("racket.scores.enter")
            } else {
                Text(ex.racketState.isDecided ? "Not played" : "Next").font(SnappetType.detail).foregroundStyle(SnappetColor.textTertiary)
            }
        }
    }

    // MARK: Interrupted / InterruptedStop (review5 H1)

    @ViewBuilder private func interruptedPanel(_ m: RacketRecordingMachine, _ reason: RacketInterruption) -> some View {
        let route = m.endRoute
        Text(RacketRecordingRoutes.header(mode: m.racketMode, recording: m.recording, unit: unit,
                                          unitNumber: ex.racketState.units.count + 1,
                                          block: m.currentBlock, blocks: m.plan?.blocks ?? 1))
            .snappetLabel()
            .accessibilityIdentifier("racket.int.header")
        Text(reason.headline).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("racket.int.reason")
        footnote("Everything up to \(RacketClock.elapsed(m.log?.savedUpToSec ?? 0)) is saved in Photos.")
        footnote(reason.advice)
        if reason.canResume {
            primary("Resume recording", id: "racket.int.resume") { act { $0.resume(now: Date()) } }
            footnote("Resume on the phone: it starts a new part of the same game, drill block or recording.")
        } else if RacketRecordingRoutes.allowsScoringWithoutVideo(mode: m.racketMode) {
            secondary("Keep scoring without video", id: "racket.int.keepScoring") { act { $0.continueWithoutVideo(now: Date()) } }
        }
        Button { act { $0.end(now: Date()) } } label: {
            Text(RacketRecordingRoutes.endLabel(route)).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SnappetColor.perfHard)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(Capsule().strokeBorder(SnappetColor.perfHard, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.int.end")
    }

    // MARK: Still playing? (review5 M4: the configured threshold, everywhere)

    @ViewBuilder private func stillPlayingPanel(_ m: RacketRecordingMachine) -> some View {
        let minutes = Int((m.stillPlayingSec ?? 3600) / 60)
        let asked = m.stillPlayingAskedAt ?? now
        let left = max(0, RacketStillPlaying.answerWindowSec - now.timeIntervalSince(asked))
        Text("Still playing?").font(.system(size: 22, weight: .semibold)).accessibilityIdentifier("racket.still.title")
        footnote(RacketStillPlaying.reason(minutes: minutes))
        footnote("Recording stops in \(RacketClock.mmss(left)) if there’s no answer. Everything so far stays saved.")
        primary("Keep recording", id: "racket.still.keep") { act { $0.keepPlaying(now: Date()); return [] } }
        Button { act { $0.end(now: Date()) } } label: {
            Text("Stop recording").font(.system(size: 15, weight: .semibold)).foregroundStyle(SnappetColor.perfHard)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(Capsule().strokeBorder(SnappetColor.perfHard, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("racket.still.stop")
        footnote(RacketStillPlaying.again(minutes: minutes))
    }
}

// MARK: - Camera preview

private struct RacketCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let fake: Bool

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = fake ? UIColor(white: 0.12, alpha: 1) : .black
        if !fake {
            v.previewLayer.session = session
            v.previewLayer.videoGravity = .resizeAspectFill
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
