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
    /// "Keep for next time" after a mid-run adjustment (prompt 143) — the host saves the adjusted protocol
    /// (this routine's block / the saved preset / the session). nil = nothing to keep it to.
    var onKeep: ((TimedExerciseSpec) -> Void)? = nil
    /// Where Keep saves to, in words ("Updates this routine's Max hangs").
    var keepNote: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app

    @State private var vm: RunnerViewModel
    @State private var adjusting = false
    @State private var adjustDraft = ProtocolDraft(spec: .maxHangs)
    /// Cue style — sound + haptic / haptic only / silent. Persisted across launches so a gym preference sticks.
    @AppStorage("structuredRunner.cueMode") private var cueModeRaw = CueMode.both.rawValue

    init(exerciseName: String, spec: TimedExerciseSpec, keepNote: String? = nil,
         onKeep: ((TimedExerciseSpec) -> Void)? = nil,
         onLog: @escaping (_ setLog: SetLog) -> Void) {
        self.exerciseName = exerciseName
        self.spec = spec
        self.onLog = onLog
        self.onKeep = onKeep
        self.keepNote = keepNote
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
            // ring + count-down (Phase-6 device note). Released on disappear (prompt 135 holds, was a raw flag). (Phase 7)
            app.screenAwake.hold("intervalRunner", reason: .timer)
        }
        .onDisappear {
            app.screenAwake.release("intervalRunner")   // only THIS hold — the workout may still be open (prompt 135)
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
            // One-hand protocol: which hand, on every hang (prompt 142, wireframe frame 5B).
            if vm.state.phase.isWork, let hand = vm.state.phase.hand {
                Label(hand.label, systemImage: "hand.raised.fill")
                    .font(.title2.weight(.heavy)).tracking(2)
                    .foregroundStyle(Color(red: 0.16, green: 0.08, blue: 0.02))
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("intervalRunner.hand")
            }
            // Phase label — READY / WORK / REST, tinted per phase.
            Text(vm.state.phase.label)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(phaseTint)
                .accessibilityIdentifier("intervalRunner.phase")

            // The draining ring + tabular count-down — or, for a tap-done rep, a count-up + DONE.
            if vm.state.phase.isOpenEnded {
                openRepBody
            } else {
                ring
            }

            // Set/rep counter (hidden during lead-in / between-set rest, where there's no live rep).
            if vm.state.repIndex > 0, let hand = vm.state.phase.hand {
                Text("Set \(vm.state.setIndex)/\(vm.schedule.totalSets) · \(hand == .left ? "Left" : "Right") \(vm.state.repIndex) of \(vm.schedule.repsPerSet)")
                    .font(.headline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityIdentifier("intervalRunner.setrep")
            } else if vm.state.repIndex > 0 {
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

            // Load on the hang (prompt 142).
            if let load = vm.schedule.spec.load { loadBar(load) }
            // During a rest in a one-hand protocol: which hand is next.
            if vm.state.phase.isRest || vm.state.phase.kind == .leadIn,
               let next = vm.schedule.nextWorkHand(after: vm.state.phase) {
                Text("Next: \(next.label) hand")
                    .font(.headline.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("intervalRunner.nextHand")
            }
            // What you can change mid-run (prompt 143, wireframe frame 3): each chip opens Adjust.
            if vm.spec.mode == .repeaters || vm.spec.mode == .tabata { adjustChips }
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

    /// A self-paced ("until I tap done") rep (prompt 141, wireframe frame 5): the time counts UP and a big
    /// DONE moves on to the rest. The time taken is still logged.
    private var openRepBody: some View {
        VStack(spacing: 14) {
            Text(SetMeasure.formatDuration(vm.openRepElapsed ?? 0))
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .accessibilityIdentifier("intervalRunner.repTimer")
            Text("no time limit").font(.caption).foregroundStyle(.white.opacity(0.6))
            Button {
                vm.completeOpenRep()
                Haptics.success()
            } label: {
                Label("DONE", systemImage: "checkmark")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(Color(red: 0.16, green: 0.08, blue: 0.02))
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .disabled(vm.isPaused)
            .accessibilityIdentifier("intervalRunner.repDone")
            Text("Tap when the rep is finished")
                .font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var adjustChips: some View {
        let s = vm.spec
        return HStack(spacing: 8) {
            adjustChip("scalemass", s.load.map(TimedExerciseSpec.loadText) ?? "Bodyweight", id: "intervalRunner.adjust.load")
            if s.effectiveRepsPerSet > 1 {
                adjustChip("timer", "Rest \(SetMeasure.formatDuration(Double(s.restSec)))", id: "intervalRunner.adjust.rest")
            }
            adjustChip("repeat", "\(s.reps) reps", id: "intervalRunner.adjust.reps")
            if let hands = s.handMode {
                adjustChip("hand.raised", hands == .leftOnly ? "Left" : hands == .rightOnly ? "Right" : "L / R",
                           id: "intervalRunner.adjust.hands")
            }
        }
        .sheet(isPresented: $adjusting) { adjustSheet }
    }

    private func adjustChip(_ symbol: String, _ text: String, id: String) -> some View {
        Button {
            adjustDraft = ProtocolDraft(spec: vm.spec)
            adjusting = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(text).lineLimit(1)
                Image(systemName: "pencil").font(.caption2).opacity(0.6)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityHint("Adjust this run")
    }

    /// Adjust mid-run (wireframe frame 4, option R1): the clock keeps running underneath; changes apply
    /// from the next phase and nothing is saved to the protocol until the end-of-run choice.
    private var adjustSheet: some View {
        NavigationStack {
            Form { ProtocolEditorSections(draft: $adjustDraft, adjustOnly: true) }
                .navigationTitle("Adjust")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adjusting = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            vm.adjust(to: adjustDraft.spec)
                            adjusting = false
                            Haptics.tap()
                        }
                        .accessibilityIdentifier("adjust.done")
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    /// "Load  +10 kg · 80 kg total" (total only when bodyweight is known).
    private func loadBar(_ load: HangLoad) -> some View {
        let text = TimedExerciseSpec.loadText(load)
        let total: String? = app.userProfile.profile.weightKg.flatMap { bw in
            guard bw > 0 else { return nil }
            let unit: WeightUnit = load.unitRaw == "lb" ? .lb : .kg
            let v = (WorkoutMath.kgToUnit(load.totalKg(bodyweightKg: bw), unit) * 10).rounded() / 10
            return "\(SetMeasure.formatWeight(v)) \(unit.display) total"
        }
        return HStack {
            Text("Load").foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(total.map { "\(text) · \($0)" } ?? text).fontWeight(.bold)
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("intervalRunner.load")
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
                Text("\(SetMeasure.formatDuration(Double(vm.state.overallRemaining))) left")
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

            if vm.hasChanges {
                keepOrOnce
            } else {
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
            }

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

    /// Changed something mid-run (prompt 143, wireframe frame 6): one explicit choice. Either way the run
    /// is logged; "Keep" also saves the adjusted protocol for next time, "Just this once" doesn't.
    @ViewBuilder private var keepOrOnce: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOU CHANGED").font(.caption.weight(.heavy)).tracking(1).foregroundStyle(.white.opacity(0.6))
            ForEach(ProtocolChanges.lines(from: vm.originalSpec, to: vm.spec), id: \.self) { line in
                Text(line).font(.subheadline).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("intervalRunner.changes")

        if let onKeep {
            Button {
                onKeep(vm.spec)
                onLog(vm.buildSetLog())
                dismiss()
            } label: {
                Text("Keep for next time")
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(SnappetColor.workout, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intervalRunner.keep")
        }
        Button {
            onLog(vm.buildSetLog())
            dismiss()
        } label: {
            Text(onKeep == nil ? "Log set" : "Just this once")
                .font(.headline).foregroundStyle(onKeep == nil ? .white : SnappetColor.workout)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(onKeep == nil ? AnyShapeStyle(SnappetColor.workout) : AnyShapeStyle(.white.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(onKeep == nil ? "intervalRunner.logSet" : "intervalRunner.justOnce")
        if let keepNote, onKeep != nil {
            Text(keepNote).font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
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
    /// The timeline being run — rebuilt when the protocol is adjusted mid-run (prompt 143).
    private(set) var schedule: IntervalSchedule
    /// The protocol as it started, to tell whether anything was changed during the run.
    let originalSpec: TimedExerciseSpec
    /// The protocol as it is now (after any mid-run adjustments).
    var spec: TimedExerciseSpec { schedule.spec }
    var hasChanges: Bool { spec != originalSpec }

    /// Work completed before the last adjustment, banked so the rebuilt timeline can't re-count or lose it.
    private var bankedTUT: TimeInterval = 0
    private var bankedReps = 0
    private var bankedSets = 0
    /// Phases starting before this schedule time were completed under an earlier version of the protocol.
    private var countFrom: Double = 0
    /// Maps banked open-rep durations onto the rebuilt timeline's open phases.
    private var openCompletedAdjust = 0
    /// Load at each adjustment, for the end card ("+10 kg → +12.5 kg from set 2").
    private(set) var loadChanges: [(setIndex: Int, load: HangLoad?)] = []

    private(set) var startedAt: Date?
    private(set) var accumulated: TimeInterval = 0
    private(set) var now: Date = Date()
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

    /// The wall clock — injectable so the run's time accounting is unit-tested without sleeping.
    private let clock: () -> Date

    init(spec: TimedExerciseSpec, clock: @escaping () -> Date = { Date() }) {
        self.schedule = IntervalSchedule(spec: spec)
        self.originalSpec = spec
        self.clock = clock
    }

    /// Apply a mid-run edit (load / rest / reps / hands). It takes effect from the next phase; the phase in
    /// progress keeps its remaining time, completed work is banked, and nothing already done is repeated.
    func adjust(to newSpec: TimedExerciseSpec) {
        guard !isFinished, newSpec != spec else { return }
        now = clock()
        let current = state
        // Bank only FULLY completed work: the phase in progress continues in the rebuilt timeline and is
        // counted there once (banking its partial time too double-counted it).
        let done = completedWork(includePartial: false)
        bankedTUT += done.tut
        bankedReps += done.reps
        bankedSets = max(bankedSets, done.sets)
        if newSpec.load != spec.load { loadChanges.append((max(1, current.setIndex), newSpec.load)) }

        let newSchedule = IntervalSchedule(spec: newSpec)
        let map = schedule.remap(current: current, to: newSchedule)
        let openRunning = openRepElapsed
        schedule = newSchedule
        countFrom = map.countFrom
        openCompletedAdjust = map.openRepsBefore - openRepDurations.count
        // Re-anchor wall time so schedule time == the remapped point (open-rep time stays banked on top).
        accumulated = map.scheduleElapsed + openBanked + (openRunning ?? 0)
        startedAt = isPaused ? nil : clock()
        if let openRunning { openRepStartedAt = accumulated - openRunning }
        lastPhaseID = state.phase.id   // same phase continues — no transition cue
    }

    /// Elapsed seconds since the anchor (banked + running segment), floored at 0.
    var elapsed: TimeInterval {
        let running = startedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, accumulated + running)
    }

    // MARK: Self-paced reps (prompt 141)

    /// Wall-elapsed at which the current open-ended ("until I tap done") rep began; nil when not in one.
    private(set) var openRepStartedAt: TimeInterval?
    /// Durations of the completed open-ended reps, in order.
    private(set) var openRepDurations: [TimeInterval] = []
    private var openBanked: TimeInterval { openRepDurations.reduce(0, +) }

    /// Seconds into the current open-ended rep (counts up), nil when not in one.
    var openRepElapsed: TimeInterval? { openRepStartedAt.map { max(0, elapsed - $0) } }

    /// Schedule time: wall time minus time spent inside open-ended reps. The protocol clock is frozen while
    /// a tap-done rep is in progress, then carries on exactly where it stopped.
    var scheduleElapsed: TimeInterval {
        max(0, elapsed - openBanked - (openRepElapsed ?? 0))
    }

    /// The live timeline read.
    var state: IntervalSchedule.State {
        schedule.state(at: scheduleElapsed, completedOpenReps: openRepDurations.count + openCompletedAdjust)
    }

    /// DONE on a tap-done rep: bank its time and move on to what follows.
    func completeOpenRep() {
        guard !isFinished, let rep = openRepElapsed else { return }
        openRepDurations.append(rep)
        openRepStartedAt = nil
        lastPhaseID = nil   // let the next tick fire the transition cue
        now = clock()
        tickEffects()
    }

    // MARK: - Lifecycle

    func start() {
        guard startedAt == nil, !isFinished else { return }
        startedAt = clock()
        now = clock()
        // Prime so the first work-start cue fires when we leave the lead-in (not on appear).
        lastPhaseID = state.phase.id
        runTicker()
    }

    func togglePause() {
        guard !isFinished else { return }
        if isPaused {
            // Resume.
            startedAt = clock()
            now = clock()
            isPaused = false
            runTicker()
        } else {
            // Pause: fold the running segment into accumulated.
            if let s = startedAt {
                accumulated = max(0, accumulated + clock().timeIntervalSince(s))
            }
            startedAt = nil
            isPaused = true
            now = clock()
            endTicking()
        }
    }

    /// Jump the anchor to the start of the next phase boundary (Skip). If that lands past the end, finish.
    func skipPhase() {
        guard !isFinished else { return }
        // Skipping a tap-done rep is the same as finishing it.
        if state.phase.isOpenEnded {
            if openRepStartedAt == nil { enterOpenRep(state) }
            completeOpenRep()
            return
        }
        let e = scheduleElapsed
        // Find the end-of-current-phase boundary.
        var boundary = 0.0
        for phase in schedule.phases where phase.durationSec > 0 {
            boundary += Double(phase.durationSec)
            if e < boundary { break }
        }
        // Past the last timed phase is only the end if no tap-done rep is still waiting there.
        let completedOpen = openRepDurations.count + openCompletedAdjust
        if boundary >= Double(schedule.totalSeconds),
           schedule.state(at: boundary, completedOpenReps: completedOpen).isDone {
            finish(early: false)
            return
        }
        // Move the anchor so schedule time == boundary (open-rep time stays banked on top).
        accumulated = boundary + openBanked
        startedAt = isPaused ? nil : clock()
        now = clock()
        // Let the next tick fire the transition cue.
        lastPhaseID = nil
    }

    /// STOP — end the run now, capturing what was completed so far.
    func stopEarly() {
        finish(early: true)
    }

    func syncToWallClock() {
        guard !isPaused, !isFinished, startedAt != nil else { return }
        now = clock()
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
                self.now = self.clock()
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
        // Entering a tap-done rep: freeze the protocol clock at the exact start of the phase.
        if st.phase.isOpenEnded, openRepStartedAt == nil { enterOpenRep(st) }

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

    /// Start timing an open-ended rep. The tick that noticed it may be a little late, so anchor the rep
    /// at the moment schedule time crossed the phase start (no lost or double-counted rest).
    private func enterOpenRep(_ st: IntervalSchedule.State) {
        let overshoot = max(0, (elapsed - openBanked) - st.startOfPhase)
        openRepStartedAt = elapsed - overshoot
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
            accumulated = max(0, accumulated + clock().timeIntervalSince(s))
            startedAt = nil
        }
        now = clock()
        isFinished = true
        endTicking()
        capturedFinishedEarly = early
        cueSink?(.finished)
    }

    private var capturedFinishedEarly = false

    // MARK: - Capture

    /// Timed work completed on the CURRENT timeline since the last adjustment (phases starting at or after
    /// `countFrom`), including a partial work phase when stopped mid-hang. Open reps are counted separately.
    private func completedWork(includePartial: Bool = true) -> (tut: TimeInterval, reps: Int, sets: Int) {
        let e = scheduleElapsed
        var tut = 0.0, reps = 0, sets = 0
        var startOfPhase = 0.0
        for phase in schedule.phases where phase.durationSec > 0 {
            let end = startOfPhase + Double(phase.durationSec)
            if phase.kind == .work, startOfPhase >= countFrom {
                if e >= end {
                    tut += Double(phase.durationSec)
                    reps += 1
                    sets = max(sets, phase.setIndex)
                } else if includePartial, e > startOfPhase {
                    tut += e - startOfPhase
                }
            }
            startOfPhase = end
        }
        return (tut, reps, sets)
    }

    /// The pre-filled capture: time-under-tension (completed work seconds), completed reps·sets, avg/peak HR.
    var capture: Capture {
        let work = completedWork()
        var tut = bankedTUT + work.tut
        var completedReps = bankedReps + work.reps
        var completedSets = max(bankedSets, work.sets)
        // Tap-done reps: their real durations, plus an unfinished one if stopped mid-rep.
        tut += openRepDurations.reduce(0, +) + (openRepElapsed ?? 0)
        completedReps += openRepDurations.count
        let openPhases = schedule.phases.filter(\.isOpenEnded)
        let doneOpen = min(openPhases.count, openRepDurations.count + openCompletedAdjust)
        if doneOpen > 0 { completedSets = max(completedSets, openPhases[doneOpen - 1].setIndex) }
        let avg = hrCount > 0 ? Int((hrSum / Double(hrCount)).rounded()) : nil
        let peak = hrPeak > 0 ? Int(hrPeak.rounded()) : nil
        return Capture(tut: tut, completedReps: completedReps, completedSets: max(completedSets, 0),
                       avgHR: avg, peakHR: peak, finishedEarly: capturedFinishedEarly)
    }

    /// Build the `SetLog` to commit — the time-under-tension as the duration (the timed-set contract).
    func buildSetLog() -> SetLog {
        var log = SetLog(durationSec: capture.tut > 0 ? capture.tut : nil)
        // The load / hands in effect at the end (an adjusted run records what it finished on).
        log.loadKg = spec.load?.signedKg
        log.handModeRaw = spec.handMode?.rawValue
        return log
    }
}
