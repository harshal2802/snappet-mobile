import SwiftUI
import UIKit
import AudioToolbox
import HighlightEngine

/// The **structured interval runner** (Quick Session redesign Phase 6): a dark, glass, full-screen cover
/// that runs a `.repeaters` / `.tabata` / `.emom` timed exercise off its `IntervalSchedule` — a 3-2-1
/// lead-in, a big WORK / REST phase label, a draining count-down ring, a "Set i/n · Rep j/m" counter, a
/// "next ▸ …" preview chip, per-phase color (WORK = `SnappetColor.workout` ember / REST = a muted tint),
/// and audio + haptic cues. On finish (or STOP) it shows a **capture card** pre-filled with the completed
/// reps·sets + total time-under-tension (and avg/peak HR if present); "Log set" commits a
/// `SetLog(durationSec: TUT)` under the exercise — "the timer is the log".
///
/// **Timing** is wall-clock-backed exactly like `StopwatchViewModel`: the displayed phase/remaining is a
/// pure read of `IntervalSchedule.state(at:)` from the elapsed-since-anchor, so it can't drift and
/// survives backgrounding. A ~200 ms ticker only refreshes the digits + fires the per-phase cue and the
/// final-3s ticks. Pause folds the running segment into `accumulated` (the stopwatch freeze idiom); Skip
/// jumps the anchor forward to the next phase boundary.
///
/// The simple modes (`.openCountUp` / `.maxHang` / `.countDown`) stay on Phase 5's `StopwatchView` path —
/// this runner is only presented for `spec.mode.isStructured`.
struct StructuredTimedRunner: View {
    let exerciseName: String
    let spec: TimedExerciseSpec
    /// Commit funnel: a `SetLog` with the captured time-under-tension (+ rep/set counts in the log row via
    /// the duration; HR is for the capture card display only). Mirrors the timed `appendLog` path.
    let onLog: (_ setLog: SetLog) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app

    @State private var vm: RunnerViewModel
    /// Cue style — sound + haptic / haptic only / silent. Persisted across launches so a gym preference sticks.
    @AppStorage("structuredRunner.cueMode") private var cueModeRaw = CueMode.both.rawValue

    init(exerciseName: String, spec: TimedExerciseSpec,
         onLog: @escaping (_ setLog: SetLog) -> Void) {
        self.exerciseName = exerciseName
        self.spec = spec
        self.onLog = onLog
        _vm = State(initialValue: RunnerViewModel(spec: spec))
    }

    private var cueMode: CueMode { CueMode(rawValue: cueModeRaw) ?? .both }

    var body: some View {
        ZStack {
            // A FOCUS base that telegraphs the phase before the beep: ember-tinted for WORK, near-black /
            // muted for REST + lead-in. The whole backdrop shifts so it reads from across the room.
            phaseBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                topRow
                Spacer()
                if vm.isFinished {
                    captureCard
                } else {
                    runningBody
                }
                Spacer()
                if !vm.isFinished { bottomControls }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.cueSink = { [self] cue in fire(cue) }
            vm.hrSink = { app.liveWorkout.latestHR }
            vm.start()
            // Keep the screen awake through the interval run — a sleeping screen mid-set hid the phase
            // ring + count-down (Phase-6 device note). Cheaply reverted on disappear. (Phase 7)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            vm.endTicking()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.syncToWallClock() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: vm.state.phase.kind)
    }

    // MARK: - Background

    private var phaseBackground: some View {
        let top: Color
        let bottom: Color
        switch vm.state.phase.kind {
        case .work:
            top = SnappetColor.workout.opacity(0.42)
            bottom = Color(red: 0.10, green: 0.04, blue: 0.0)
        case .rest, .restBetweenSets:
            top = Color(red: 0.06, green: 0.09, blue: 0.13)
            bottom = Color.black
        case .leadIn, .done:
            top = Color(red: 0.05, green: 0.05, blue: 0.08)
            bottom = Color.black
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Top row (name · cue toggle)

    private var topRow: some View {
        HStack {
            Text(exerciseName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .accessibilityIdentifier("intervalRunner.name")
            Spacer()
            Button {
                cueModeRaw = cueMode.next.rawValue
                Haptics.tap()
            } label: {
                Image(systemName: cueMode.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intervalRunner.cueToggle")
            .accessibilityLabel("Cues: \(cueMode.label)")
        }
    }

    // MARK: - Running body (lead-in or phase)

    @ViewBuilder private var runningBody: some View {
        VStack(spacing: 18) {
            // Phase label — READY / WORK / REST, tinted per phase.
            Text(vm.state.phase.label)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(phaseTint)
                .accessibilityIdentifier("intervalRunner.phase")

            // The draining ring + tabular count-down.
            ring

            // Set/rep counter (hidden during lead-in / between-set rest, where there's no live rep).
            if vm.state.repIndex > 0 {
                Text("Set \(vm.state.setIndex)/\(vm.schedule.totalSets) · Rep \(vm.state.repIndex)/\(vm.schedule.repsPerSet)")
                    .font(.headline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityIdentifier("intervalRunner.setrep")
            } else if vm.state.phase.kind == .restBetweenSets {
                Text("Set \(vm.state.setIndex)/\(vm.schedule.totalSets) done")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityIdentifier("intervalRunner.setrep")
            }

            // Next-phase preview chip.
            if let next = vm.state.phase.nextLabel {
                Label("next ▸ \(next)", systemImage: "arrow.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
                    .accessibilityIdentifier("intervalRunner.next")
            }

            // Live-HR chip (only when present).
            if let bpm = app.liveWorkout.latestHR { hrChip(bpm) }

            if vm.isPaused {
                Text("PAUSED")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var phaseTint: Color {
        switch vm.state.phase.kind {
        case .work:                    return SnappetColor.workout
        case .rest, .restBetweenSets:  return Color(red: 0.55, green: 0.74, blue: 0.95)
        case .leadIn, .done:           return .white
        }
    }

    /// The draining ring (remaining / phase duration) + tabular count-down, the `StopwatchView` count-down
    /// dial's shape. Under Reduce Motion the trim snaps instead of animating.
    private var ring: some View {
        let dur = max(1, vm.state.phase.durationSec)
        let remaining = vm.state.remainingInPhase
        let frac = CGFloat(remaining) / CGFloat(dur)
        return ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0, min(1, frac)))
                .stroke(phaseTint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: remaining)
            VStack(spacing: 2) {
                Text(SetMeasure.formatDuration(Double(remaining)))
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("intervalRunner.timer")
                Text("\(vm.state.overallRemaining)s left")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 240, height: 240)
    }

    private func hrChip(_ bpm: Double) -> some View {
        let maxHR = app.userProfile.profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR
        let zone = HeartRateZone.forBpm(bpm, maxHR: maxHR)
        return HStack(spacing: 8) {
            Image(systemName: "heart.fill").foregroundStyle(zone.color)
            Text("\(Int(bpm.rounded())) bpm")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("intervalRunner.hr")
    }

    // MARK: - Bottom controls (Pause · Skip · STOP)

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButton(vm.isPaused ? "Resume" : "Pause",
                              systemImage: vm.isPaused ? "play.fill" : "pause.fill",
                              id: "intervalRunner.pause") {
                    vm.togglePause()
                    Haptics.tap()
                }
                controlButton("Skip", systemImage: "forward.fill", id: "intervalRunner.skip") {
                    vm.skipPhase()
                    Haptics.tap()
                }
            }
            Button {
                vm.stopEarly()
            } label: {
                Text("STOP")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intervalRunner.stop")
        }
    }

    private func controlButton(_ title: String, systemImage: String, id: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - Capture card ("the timer is the log")

    private var captureCard: some View {
        let cap = vm.capture
        return VStack(spacing: 16) {
            Text(cap.finishedEarly ? "Stopped" : "Complete")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text(SetMeasure.formatDuration(cap.tut))
                .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(SnappetColor.workout)
                .accessibilityIdentifier("intervalRunner.captureTUT")

            VStack(spacing: 8) {
                captureRow("Time under tension", SetMeasure.formatDuration(cap.tut))
                captureRow("Completed", "\(cap.completedReps) rep\(cap.completedReps == 1 ? "" : "s") · \(cap.completedSets) set\(cap.completedSets == 1 ? "" : "s")")
                if let avg = cap.avgHR {
                    captureRow("Avg HR", "\(avg) bpm")
                }
                if let peak = cap.peakHR {
                    captureRow("Peak HR", "\(peak) bpm")
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                onLog(vm.buildSetLog())
                dismiss()
            } label: {
                Label("Log set", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(SnappetColor.workout, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intervalRunner.logSet")

            Button {
                dismiss()
            } label: {
                Text("Discard")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intervalRunner.discard")
        }
    }

    private func captureRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value).foregroundStyle(.white).font(.body.weight(.semibold).monospacedDigit())
        }
        .font(.subheadline)
    }

    // MARK: - Cues

    /// Play the cue for a transition, gated by the user's sound/haptic/silent preference. Sounds are light
    /// `AudioServicesPlaySystemSound` system tones (no asset); haptics are the shared `Haptics` helper.
    private func fire(_ cue: RunnerViewModel.Cue) {
        let mode = cueMode
        switch cue {
        case .workStart:
            if mode.haptic { Haptics.success() }
            if mode.sound { AudioServicesPlaySystemSound(1057) }   // "Tink" — sharp work start
        case .restStart:
            if mode.haptic { Haptics.warning() }
            if mode.sound { AudioServicesPlaySystemSound(1103) }   // "Tock" — softer rest start
        case .countdownTick:
            if mode.haptic { Haptics.tap() }
            if mode.sound { AudioServicesPlaySystemSound(1104) }   // light tick for the final 3 s
        case .finished:
            if mode.haptic { Haptics.success() }
            if mode.sound { AudioServicesPlaySystemSound(1025) }   // completion fanfare-ish
        }
    }

    // MARK: - Cue mode

    enum CueMode: String, CaseIterable {
        case both, hapticOnly, silent
        var sound: Bool { self == .both }
        var haptic: Bool { self == .both || self == .hapticOnly }
        var next: CueMode {
            switch self {
            case .both:       return .hapticOnly
            case .hapticOnly: return .silent
            case .silent:     return .both
            }
        }
        var symbol: String {
            switch self {
            case .both:       return "speaker.wave.2.fill"
            case .hapticOnly: return "iphone.radiowaves.left.and.right"
            case .silent:     return "speaker.slash.fill"
            }
        }
        var label: String {
            switch self {
            case .both:       return "sound + haptic"
            case .hapticOnly: return "haptic only"
            case .silent:     return "silent"
            }
        }
    }
}

/// The runner's wall-clock engine: drives off an `IntervalSchedule` + a `startedAt` / `accumulated` anchor
/// (the `StopwatchViewModel` freeze idiom), recomputes the live `State` each ~200 ms tick, fires the
/// per-phase + final-3s cues on the transitions, and accumulates HR samples for the capture card.
@MainActor @Observable
final class RunnerViewModel {
    let schedule: IntervalSchedule

    private(set) var startedAt: Date?
    private(set) var accumulated: TimeInterval = 0
    private(set) var now: Date = .now
    private(set) var isPaused = false
    private(set) var isFinished = false

    /// Set externally (by the view) to play a cue; nil-safe.
    var cueSink: ((Cue) -> Void)?
    /// Set externally to read the current live HR (so the engine stays view-free).
    var hrSink: (() -> Double?)?

    private var ticker: Task<Void, Never>?
    private var lastPhaseID: Int?
    private var lastTickRemaining: Int?
    /// HR accumulator for avg/peak across the run.
    private var hrSum = 0.0
    private var hrCount = 0
    private var hrPeak = 0.0

    enum Cue { case workStart, restStart, countdownTick, finished }

    /// The capture card's pre-fill.
    struct Capture {
        var tut: TimeInterval
        var completedReps: Int
        var completedSets: Int
        var avgHR: Int?
        var peakHR: Int?
        var finishedEarly: Bool
    }

    init(spec: TimedExerciseSpec) {
        self.schedule = IntervalSchedule(spec: spec)
    }

    /// Elapsed seconds since the anchor (banked + running segment), floored at 0.
    var elapsed: TimeInterval {
        let running = startedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, accumulated + running)
    }

    /// The live timeline read.
    var state: IntervalSchedule.State { schedule.state(at: elapsed) }

    // MARK: - Lifecycle

    func start() {
        guard startedAt == nil, !isFinished else { return }
        startedAt = .now
        now = .now
        // Prime so the first work-start cue fires when we leave the lead-in (not on appear).
        lastPhaseID = state.phase.id
        runTicker()
    }

    func togglePause() {
        guard !isFinished else { return }
        if isPaused {
            // Resume.
            startedAt = .now
            now = .now
            isPaused = false
            runTicker()
        } else {
            // Pause: fold the running segment into accumulated.
            if let s = startedAt {
                accumulated = max(0, accumulated + Date.now.timeIntervalSince(s))
            }
            startedAt = nil
            isPaused = true
            now = .now
            endTicking()
        }
    }

    /// Jump the anchor to the start of the next phase boundary (Skip). If that lands past the end, finish.
    func skipPhase() {
        guard !isFinished else { return }
        let e = elapsed
        // Find the end-of-current-phase boundary.
        var boundary = 0.0
        for phase in schedule.phases where phase.durationSec > 0 {
            boundary += Double(phase.durationSec)
            if e < boundary { break }
        }
        if boundary >= Double(schedule.totalSeconds) {
            finish(early: false)
            return
        }
        // Move the anchor so elapsed == boundary.
        accumulated = boundary
        startedAt = isPaused ? nil : .now
        now = .now
        // Let the next tick fire the transition cue.
        lastPhaseID = nil
    }

    /// STOP — end the run now, capturing what was completed so far.
    func stopEarly() {
        finish(early: true)
    }

    func syncToWallClock() {
        guard !isPaused, !isFinished, startedAt != nil else { return }
        now = .now
        tickEffects()
    }

    func endTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func runTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.now = .now
                self.tickEffects()
            }
        }
    }

    /// Per-tick: sample HR, fire phase-transition + final-3s cues, and auto-finish at the end.
    private func tickEffects() {
        guard !isFinished else { return }
        sampleHR()

        let st = state
        if st.isDone {
            finish(early: false)
            return
        }

        // Phase transition → work/rest cue.
        if lastPhaseID != st.phase.id {
            lastPhaseID = st.phase.id
            lastTickRemaining = st.remainingInPhase
            switch st.phase.kind {
            case .work:                    cueSink?(.workStart)
            case .rest, .restBetweenSets:  cueSink?(.restStart)
            case .leadIn, .done:           break
            }
        }

        // Final-3s countdown ticks within a phase (each whole-second step at 3/2/1).
        if let last = lastTickRemaining, last != st.remainingInPhase {
            lastTickRemaining = st.remainingInPhase
            if (1...3).contains(st.remainingInPhase) {
                cueSink?(.countdownTick)
            }
        } else if lastTickRemaining == nil {
            lastTickRemaining = st.remainingInPhase
        }
    }

    private func sampleHR() {
        guard let bpm = hrSink?(), bpm > 0 else { return }
        hrSum += bpm
        hrCount += 1
        hrPeak = max(hrPeak, bpm)
    }

    private func finish(early: Bool) {
        guard !isFinished else { return }
        // Bank the final elapsed so `capture` reads a stable value.
        if let s = startedAt {
            accumulated = max(0, accumulated + Date.now.timeIntervalSince(s))
            startedAt = nil
        }
        now = .now
        isFinished = true
        endTicking()
        capturedFinishedEarly = early
        cueSink?(.finished)
    }

    private var capturedFinishedEarly = false

    // MARK: - Capture

    /// The pre-filled capture: time-under-tension (completed work seconds), completed reps·sets, avg/peak HR.
    var capture: Capture {
        let e = elapsed
        var tut = 0.0
        var completedReps = 0
        var completedSets = 0
        var startOfPhase = 0.0
        for phase in schedule.phases where phase.durationSec > 0 {
            let end = startOfPhase + Double(phase.durationSec)
            if phase.kind == .work {
                if e >= end {
                    tut += Double(phase.durationSec)   // fully completed work
                    completedReps += 1
                    completedSets = max(completedSets, phase.setIndex)
                } else if e > startOfPhase {
                    tut += e - startOfPhase              // partial (when stopped mid-work)
                }
            }
            startOfPhase = end
        }
        let avg = hrCount > 0 ? Int((hrSum / Double(hrCount)).rounded()) : nil
        let peak = hrPeak > 0 ? Int(hrPeak.rounded()) : nil
        return Capture(tut: tut, completedReps: completedReps, completedSets: max(completedSets, 0),
                       avgHR: avg, peakHR: peak, finishedEarly: capturedFinishedEarly)
    }

    /// Build the `SetLog` to commit — the time-under-tension as the duration (the timed-set contract).
    func buildSetLog() -> SetLog {
        SetLog(durationSec: capture.tut > 0 ? capture.tut : nil)
    }
}
