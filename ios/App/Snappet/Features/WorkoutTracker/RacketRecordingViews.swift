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
    /// "Back" when it follows a setup screen (TtStorage; V2.4), "Cancel" from the match / drill page.
    var cancelLabel: String = "Cancel"
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
                        Text("Record everything").font(.system(size: 15, weight: .semibold))
                        Text("For this match or drill").snappetLabel()
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
                        // TtStorage's bar: "41 GB free of 256 GB" (V2.4) — used space filled, free space empty.
                        VStack(alignment: .leading, spacing: 6) {
                            if storage.total > 0 {
                                GeometryReader { g in
                                    let used = 1 - min(1, max(0, Double(storage.free) / Double(storage.total)))
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.08))
                                        Capsule().fill(SnappetColor.textSecondary).frame(width: max(6, g.size.width * used))
                                    }
                                }
                                .frame(height: 10)
                                .accessibilityElement()
                                .accessibilityLabel("Phone storage: \(RacketStorageCheck.gigabytes(storage.free)) free of \(RacketStorageCheck.gigabytes(storage.total))")
                                .accessibilityIdentifier("racket.storage.bar")
                            }
                            HStack {
                                Text("\(RacketStorageCheck.gigabytes(storage.free)) free")
                                Spacer()
                                if storage.total > 0 { Text(RacketStorageCheck.gigabytes(storage.total)).foregroundStyle(SnappetColor.textSecondary) }
                            }
                            .font(SnappetType.body.monospacedDigit())
                        }
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
                    Button(cancelLabel) { dismiss() }.accessibilityIdentifier("racket.storage.cancel")
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
    /// The session, for the split flow after a whole-match recording (prompt 246: it edits the match directly).
    var session: WorkoutSession? = nil
    /// A game / set tallied point by point on the Apple Watch finished: log it "from Watch" (prompt 245).
    var onWatchUnit: (SetLog) -> Void = { _ in }
    /// The latest heart rate (Stats "Heart rate", prompt 249); nil ⇒ "–".
    var heartRate: Double? = nil
    let onClose: () -> Void

    @State private var recorder = RacketRecorder()
    /// Warm (prompt 249): serious heat pauses the camera view; recording continues.
    @State private var thermal: RacketThermalLevel = .ok
    @State private var machine: RacketRecordingMachine?
    @State private var now = Date()
    /// Dim · Camera · Stats (device feedback round 1: opens on the camera so the shot can be framed).
    @State private var show: RacketRecordingShow = .initial
    @State private var idleTimerWas = false
    @State private var storageFree: Int64?
    /// Measured write rate + live free space (sampled every 5 s) for "space left".
    @State private var meter = RacketWriteRateMeter()
    @State private var ticks = 0
    /// Games already logged when the recording began; the split reads the recording's own games from here.
    @State private var baseSets = 0
    /// The Watch's point tally for the game being played (a match recording everything, prompt 245).
    @State private var liveScore: RacketLiveScore?
    /// Units the Watch logged during this recording (the next one's rules — a super tiebreak — follow from it).
    @State private var watchUnitsLogged = 0

    private var unit: RacketUnit { ex.racketFormat.sport.unit }
    private var title: String { ex.isRacketMatch ? ex.racketMatchTitle : (ex.displayName ?? "Drill") }

    var body: some View {
        if let session, let m = machine, m.phase == .ended(.splitPrompt) {
            // TtSplitPrompt → Review → Assign → Done (prompt 246), in place of step 1's "Recording saved" placeholder.
            RacketVideosCover(session: session, start: .splitPrompt(ex.id), onClose: onClose)
        } else {
            recordingBody
        }
    }

    private var recordingBody: some View {
        ZStack {
            VStack(spacing: 12) {
                topBar
                if let m = machine {
                    if thermal != .ok, !m.isEnded { warmBanner }
                    if thermal == .ok, RacketRecordingShow.showsPreview(show, phase: m.phase) {
                        cameraView.layoutPriority(1)
                    }
                    content(m)
                    if RacketRecordingShow.showsSwitcher(phase: m.phase), thermal == .ok { switcher }
                    bottomAction(m)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let m = machine, let reason = m.interruption {
                overlayPanel { interruptedPanel(m, reason) }
            } else if let m = machine, m.stillPlayingAskedAt != nil {
                overlayPanel { stillPlayingPanel(m) }
            }
        }
        .racketPersistentPreview(session: recorder.session, fake: recorder.fake)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { recorder.screenAppeared(); setUp() }
        .onDisappear {
            let was = idleTimerWas, id = ex.id
            recorder.screenDisappeared {
                UIApplication.shared.isIdleTimerDisabled = was
                RacketWatchRelay.shared.detach(id)
            }
        }
        // The Watch mirrors this screen (prompt 245): every change of what it should show is sent.
        .onChange(of: watchState) { _, s in if let s { RacketWatchRelay.shared.publish(s) } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                now = Date()
                act { $0.tick(now: now) }
                if let m = machine, m.interruption == nil { recorder.ensureCapturing(m.capturing) }
                ticks += 1
                if ticks % 10 == 0 { sampleStorage() }
            }
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
        let kind: RacketRecordingMachine.Kind = .match
        var m = RacketRecordingMachine(kind: kind, recording: .everything,
                                       stillPlayingMinutes: defaults.stillPlayingMinutes(for: .everything), now: Date())
        m.baseSetIndex = baseSets
        m.quality = quality
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
        recorder.onThermal = { level in thermal = level }
        thermal = recorder.thermal
        recorder.startPreview(quality: quality)
        if ex.isRacketMatch { liveScore = RacketLiveScore(rules: watchRules(unitIndex: baseSets)) }
        RacketWatchRelay.shared.attach(ex.id) { command, now in handleWatch(command, now: now) }
        // "A match starts recording now"; a drill waits on the camera for "Start block 1".
        let effects = ex.isRacketMatch ? m.start(now: Date()) : []
        machine = m
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

    /// The live preview from the recorder's own session (no second session). The simulator / UI tests show a stand-in.
    private var cameraView: some View {
        Color.clear.racketPreviewSlot()
            .overlay {
                if recorder.fake {
                    Text("Camera preview shows here on a device")
                        .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                        .accessibilityIdentifier("racket.rec.previewStandIn")
                }
            }
            // The drill's camera step frames the shot: the court-check placeholder guide (device feedback round 2).
            .overlay { if machine?.phase == .ready { RacketCourtGuide(sport: ex.racketFormat.sport) } }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera view")
            .accessibilityIdentifier("racket.rec.preview")
    }

    /// TtRecordAll / CameraView / Dim boards: status · what's recording · saved.
    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusPill
            Spacer(minLength: 4)
            if ex.isRacketMatch, machine?.isEnded == false {
                Text("Match, everything").font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("racket.rec.header")
                Spacer(minLength: 4)
                if thermal != .ok {
                    Text(thermal.headerLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(SnappetColor.perfModerate)
                        .accessibilityIdentifier("racket.rec.warm")
                } else {
                    Text(savedLine).font(.system(size: 13)).foregroundStyle(savedColor)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("racket.rec.saved")
                }
            } else if thermal != .ok, machine?.isEnded == false {
                Text(thermal.headerLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(SnappetColor.perfModerate)
                    .accessibilityIdentifier("racket.rec.warm")
            }
        }
    }

    /// Dim · Camera · Stats (the boards' bottom row).
    private var switcher: some View {
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

    /// The phase's main action under the switcher: Stop and split (match), End block, Finish drill (rest).
    @ViewBuilder private func bottomAction(_ m: RacketRecordingMachine) -> some View {
        switch m.phase {
        case .recordingMatch:
            // V2.6: the board goes straight to the split prompt (SplitPrompt "Keep as one video" / Later is the undo).
            RacketStopButton(title: "Stop and split", id: "racket.rec.stop") { act { $0.end(now: Date()) } }
        default: EmptyView()
        }
    }

    private var savedColor: Color {
        recorder.lastSavedAt != nil && recorder.savingParts == 0 ? SnappetColor.perfFresh : SnappetColor.textSecondary
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
                    Text("Recording \(RacketClock.recordingHeader(recorded))").monospacedDigit()
                }
                .foregroundStyle(SnappetColor.perfHard)   // the boards' "● Recording" is red
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
        let compact = RacketRecordingShow.compact(show, phase: m.phase)
        switch m.phase {
        case .recordingMatch:
            if show == .stats && thermal == .ok { matchStatsPanel(m) } else { matchPanel(m, compact: compact && thermal == .ok) }
        case .ended(let route): endPanel(m, route)
        // Drills have their own cover (`RacketDrillCover`, prompt 250); this screen records a whole match.
        case .ready, .countdown, .block, .blockPaused, .rest, .restPaused, .restDone: EmptyView()
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

    // RecordAll (Stats) · CameraView (Camera) · Dim. The saved line sits in the top bar; Stop and split under the switcher.
    private func matchPanel(_ m: RacketRecordingMachine, compact: Bool) -> some View {
        let state = ex.racketState
        let room = spaceLeftSec
        return VStack(spacing: compact ? 10 : 22) {
            if !compact { Spacer(minLength: 0) }
            bigScore(state, compact: compact)
            HStack(spacing: 10) {
                stat("Marks", "\(m.log?.userMarkCount ?? 0)", compact: compact)
                stat("Space left, \(quality.label)", room.map(RacketStorageCheck.roughDuration) ?? "Unknown", compact: compact)
                    .accessibilityIdentifier("racket.rec.space")
                    .accessibilityHint(meter.isMeasured ? "Measured from what's been recorded" : "Estimated from the camera settings")
            }
            HStack(spacing: 8) {
                secondary("Mark this moment", id: "racket.rec.mark") { act { $0.mark(.moment, now: Date()); return [] }; Haptics.tap() }
                secondary("New \(unit.noun) starts", id: "racket.rec.newGame") {
                    act { $0.mark(.newGame, now: Date()); return [] }
                    if liveScore != nil { liveScore = RacketLiveScore(rules: watchRules(unitIndex: baseSets + watchUnitsLogged)) }
                    Haptics.tap()
                }
            }
            if !compact {
                footnote(RacketStillPlaying.recordAllFooter(minutes: defaults.stillPlayingEverythingMin))
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
        }
    }

    /// TtRecordAll's big number: the current game's points from the Watch ("4 – 3 · Score from Watch"); before any
    /// Watch point, the match so far ("1 – 0 · Games").
    private func bigScore(_ state: RacketScoring.MatchState, compact: Bool) -> some View {
        let big = RacketRecordStats.bigScore(live: liveScore, won: state.won, lost: state.lost, unit: unit)
        return VStack(spacing: 2) {
            Text(big.value)
                .font(.system(size: compact ? 34 : 76, weight: .light)).monospacedDigit()
                .accessibilityIdentifier("racket.rec.score")
            Text(big.caption)
                .font(.system(size: compact ? 13 : 15)).foregroundStyle(SnappetColor.textSecondary)
                .accessibilityIdentifier("racket.rec.scoreCaption")
            if let live = liveScore, !live.isEmpty {
                // Which game the Watch is on, and the match so far.
                Text("\(live.header(unitNumber: ex.sets.count + 1)) · match \(state.won)–\(state.lost)")
                    .font(SnappetType.detail.monospacedDigit()).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("racket.rec.watchScore")
            }
        }
    }

    // Stats (LiveStatsOff — tracking is off while recording everything; rally stats come from tags after the match).
    private func matchStatsPanel(_ m: RacketRecordingMachine) -> some View {
        let state = ex.racketState
        let log = m.log
        let sport = ex.racketSport ?? ex.racketFormat.sport
        let big = RacketRecordStats.bigScore(live: liveScore, won: state.won, lost: state.lost, unit: unit)
        return RacketStatsOffPanel(score: big.value,
                                   tags: RacketTagSummary.make(log?.allRallies ?? [], sport: sport),
                                   sides: RacketWatchCopy.sides(opponent: ex.opponent, doubles: ex.isDoubles), unit: unit,
                                   gameSec: log.map { RacketRecordStats.gameSec($0, now: now) } ?? 0,
                                   sessionSec: log?.recordedSec(now: now) ?? 0,
                                   pointsLabel: RacketGameCopy.pointsLabel(sport),
                                   points: RacketRecordStats.pointsPlayed(liveScore), heartRate: heartRate,
                                   afterLine: RacketGameCopy.statsAfterLine(sport))
    }

    /// Warm (PhoneWarm): the camera view pauses; recording, marks and score carry on.
    private var warmBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    private var savedLine: String {
        if recorder.savingParts > 0 { return "Saving a part…" }
        guard let at = recorder.lastSavedAt else { return "Saves every 10 min" }
        let min = Int(now.timeIntervalSince(at) / 60)
        return min < 1 ? "Saved just now" : "Saved \(min) min ago"
    }

    /// The boards' stat: light numerals over a grey label, centred.
    private func stat(_ k: String, _ v: String, compact: Bool) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: compact ? 22 : 34, weight: .light)).monospacedDigit()
            Text(k).font(.system(size: compact ? 12 : 13)).foregroundStyle(SnappetColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // A whole match ends at the split prompt (`body`, prompt 246); this "Recording saved" panel only shows when the host
    // passed no session to edit — the match is split later from Your videos. A drill ends on its own cover's review.
    @ViewBuilder private func endPanel(_ m: RacketRecordingMachine, _ route: RacketRecordingEndRoute) -> some View {
        let recorded = m.log?.recordedSec(now: now) ?? 0
        VStack(spacing: 14) {
            do {
                header("Recording saved", title)
                Text(RacketClock.elapsed(recorded))
                    .font(.system(size: 56, weight: .light)).monospacedDigit()
                    .accessibilityIdentifier("racket.rec.recorded")
                Text("recorded · \(m.log?.userMarkCount ?? 0) marks").snappetLabel()
                footnote("You can split it any time from Your videos. The original is never changed.")
            }
            if recorder.savingParts > 0 {
                Label("Saving to Photos…", systemImage: "arrow.down.circle").font(SnappetType.detail)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer(minLength: 0)
            primary("Done", id: "racket.rec.done") { onClose() }
        }
    }

    // MARK: Interrupted / InterruptedStop (review5 H1)

    @ViewBuilder private func interruptedPanel(_ m: RacketRecordingMachine, _ reason: RacketInterruption) -> some View {
        RacketInterruptionPanel(
            header: RacketRecordingRoutes.header(mode: m.racketMode, recording: m.recording, unit: unit,
                                                 unitNumber: ex.racketState.units.count + 1,
                                                 block: m.currentBlock, blocks: m.plan?.blocks ?? 1),
            reason: reason, savedUpToSec: m.log?.savedUpToSec ?? 0,
            endLabel: RacketRecordingRoutes.endLabel(m.endRoute),
            allowsKeepScoring: RacketRecordingRoutes.allowsScoringWithoutVideo(mode: m.racketMode),
            onResume: { act { $0.resume(now: Date()) } },
            onKeepScoring: { act { $0.continueWithoutVideo(now: Date()) } },
            onEnd: { act { $0.end(now: Date()) } })
    }

    // MARK: Still playing? (review5 M4: the configured threshold, everywhere)

    @ViewBuilder private func stillPlayingPanel(_ m: RacketRecordingMachine) -> some View {
        let minutes = Int((m.stillPlayingSec ?? 3600) / 60)
        let asked = m.stillPlayingAskedAt ?? now
        RacketStillPlayingPanel(minutes: minutes,
                                secondsLeft: max(0, RacketStillPlaying.answerWindowSec - now.timeIntervalSince(asked)),
                                againLine: RacketStillPlaying.again(minutes: minutes),
                                onKeep: { act { $0.keepPlaying(now: Date()); return [] } },
                                onStop: { act { $0.end(now: Date()) } })
    }
}

// MARK: - Camera preview

/// Where a screen wants the camera preview drawn (device feedback round 2). A preview layer attached to a session
/// that is already recording makes the session reconfigure, and the movie file ends with AVError -11818 ("Recording
/// Stopped") — on a phone, tapping Camera mid-game stopped the recording and showed "Snappet left the screen". So a
/// recording screen keeps ONE preview for its whole life (attached before anything records), drawn behind the content
/// at the rect a `racketPreviewSlot()` marks, and invisible (still attached) when no slot is on screen.
struct RacketPreviewSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

extension View {
    /// Marks this view's bounds as where the camera preview shows (the view itself should be clear).
    func racketPreviewSlot() -> some View {
        anchorPreference(key: RacketPreviewSlotKey.self, value: .bounds) { $0 }
    }

    /// The screen's one camera preview, drawn behind the content at the marked slot. Apply at the screen's root, under
    /// its black background.
    func racketPersistentPreview(session: AVCaptureSession, fake: Bool) -> some View {
        backgroundPreferenceValue(RacketPreviewSlotKey.self) { anchor in
            GeometryReader { g in
                let rect = anchor.map { g[$0] } ?? CGRect(x: 0, y: 0, width: 2, height: 2)
                RacketCameraPreview(session: session, fake: fake)
                    .frame(width: max(2, rect.width), height: max(2, rect.height))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(anchor == nil ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct RacketCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let fake: Bool

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var loggedSize: CGSize = .zero
        #if DEBUG
        private let debugLabel = UILabel()
        private var debugTimer: Timer?

        /// `-racketCameraDebug`: running / connection / thermal on the preview itself, readable in a device screenshot.
        func startDebugLabel() {
            debugLabel.numberOfLines = 0
            debugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            debugLabel.textColor = .yellow
            debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            addSubview(debugLabel)
            debugTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDebug() }
            }
        }

        private func refreshDebug() {
            let c = previewLayer.connection
            let s = previewLayer.session
            debugLabel.text = "running=\(s?.isRunning ?? false) interrupted=\(s?.isInterrupted ?? false) inputs=\(s?.inputs.count ?? 0)\nconnection=\(c != nil) enabled=\(c?.isEnabled ?? false) active=\(c?.isActive ?? false)\nsize=\(Int(bounds.width))x\(Int(bounds.height)) window=\(window != nil) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"
            debugLabel.frame = CGRect(x: 4, y: 4, width: bounds.width - 8, height: 48)
        }
        #endif

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != loggedSize else { return }
            loggedSize = bounds.size
            let c = previewLayer.connection
            RacketRecorder.trace("preview layout session=\(self.previewLayer.session.map { Unmanaged.passUnretained($0).toOpaque().debugDescription } ?? "nil") \(Int(self.bounds.width))x\(Int(self.bounds.height)) session=\(self.previewLayer.session != nil) running=\(self.previewLayer.session?.isRunning ?? false) connection=\(c != nil) enabled=\(c?.isEnabled ?? false) active=\(c?.isActive ?? false) hidden=\(self.isHidden) alpha=\(self.alpha)")
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        RacketRecorder.trace("preview view made (layer attaches to the session)")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-racketCameraDebug") { v.startDebugLabel() }
        #endif
        v.backgroundColor = fake ? UIColor(white: 0.12, alpha: 1) : .black
        if !fake {
            v.previewLayer.session = session
            // The whole recorded frame, letterboxed: framing must show what's actually filmed.
            v.previewLayer.videoGravity = .resizeAspect
            Self.portrait(v.previewLayer)
        }
        return v
    }

    /// The screen is portrait, so the preview is too (it reads right however the phone is propped, like the Camera
    /// app's viewfinder); the recording itself follows how the phone is held (`RacketRecorder`). The connection
    /// appears once the session has its input, so this is re-applied on update.
    func updateUIView(_ uiView: PreviewView, context: Context) {
        if !fake { Self.portrait(uiView.previewLayer) }
    }

    private static func portrait(_ layer: AVCaptureVideoPreviewLayer) {
        if let c = layer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
            c.videoRotationAngle = 90
        }
    }
}
