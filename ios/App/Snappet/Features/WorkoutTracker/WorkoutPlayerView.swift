import SwiftUI
import SwiftData
import UIKit
import HighlightEngine

/// The live workout player: walks the user set-by-set through the session's exercises, logging
/// reps + weight for each set, running a rest timer between sets, and showing a summary when
/// done. Presented full-screen. Progress is saved to the session after every set, so a session
/// survives backgrounding and can be resumed. `onClose(saved:)` reports whether to keep the
/// session (finish / save & exit) or discard it.
struct WorkoutPlayerView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    /// Completed sessions, for the cross-session "Last time: 3×8 @ 60 kg" prefill + hint (issue #73).
    let history: [WorkoutSession]
    let defaultUnit: WeightUnit
    /// Close the player and report whether to keep the session (finish / save & exit) or discard.
    let onClose: (_ saved: Bool) -> Void
    /// Dismiss the player **without** ending the workout — the session stays active, the watch
    /// keeps recording, and the Live Activity + in-app banner keep showing live metrics. Tapping
    /// the banner brings the player back. (Background-workout / navigate-back ask.)
    let onMinimize: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app
    /// Rest-timer digits and the completion seal scale with Dynamic Type (relative to largeTitle)
    /// instead of fixed 44/72pt, so enlarged-text users can read the timer and the finish state (#79).
    @ScaledMetric(relativeTo: .largeTitle) private var restTimerSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var doneSealSize: CGFloat = 72

    enum Phase { case exercise, rest, done }
    @State private var phase: Phase = .exercise
    @State private var exerciseIndex = 0
    @State private var setIndex = 0

    // Per-set input (strength — reps × weight).
    @State private var repsText = ""
    @State private var weightText = ""
    @State private var unit: WeightUnit = .kg
    // Per-set input — discipline-aware fields (workout-redesign E4). The guided player now logs any
    // discipline's effort, not just reps×weight: a climb grade+outcome, a timed/TUT duration (captured via
    // the shared StopwatchView), a run distance+duration, an RPE. These hold the in-progress entry for the
    // current set; `completeSet()` reads the right ones for `current.discipline`.
    /// Climb attempt (climb discipline): the picked outcome + the climb's prescribed grade/type/scale.
    @State private var climbStatus: KilterAscentStatus = .sent
    @State private var climbGrade = ""
    @State private var climbType: ClimbType = .boulder
    @State private var climbScale: GradeScale = .vScale
    /// Captured duration in seconds (timed/duration sets, and an optional time-under-tension on strength).
    @State private var capturedDuration: Double = 0
    /// Run leg (run discipline): distance text in the user's distance unit + minutes/seconds.
    @State private var runDistanceText = ""
    @State private var runMinutes = ""
    @State private var runSeconds = ""
    /// Optional RPE (1–10) for strength/timed/run efforts; 0 ⇒ unrated.
    @State private var rpe = 0
    /// The user's preferred distance unit, derived from the weight unit (km for kg, mi for lb).
    private var distanceUnit: DistanceUnit { unit == .lb ? .mi : .km }
    // The current exercise's cross-session "last time" (issue #73), cached by `prefillInputs()` /
    // `prefillEditing()` — the body re-renders every live HR sample (~1 Hz), so the hint must not
    // re-scan all history per render.
    @State private var lastSetHint: LastSetLookup.LastTime?

    // Rest timer.
    @State private var restRemaining = 0
    @State private var restTotal = 0
    @State private var restEndDate: Date?
    @State private var timerTask: Task<Void, Never>?
    @State private var flash = false

    // End-early dialog.
    @State private var showingEnd = false
    @State private var confirmingSkip = false

    // Paused state: the elapsed value frozen at the moment of pause (nil = running). Drives the
    // header's freeze; pause itself lives on `app.liveWorkout` so the watch + Live Activity agree.
    @State private var displayElapsedAtPause: TimeInterval?
    // Drives the one-shot completion-seal bounce (incremented when the done screen appears).
    @State private var doneBounce = 0

    private var exercises: [SessionExercise] { session.exercises }
    private var current: SessionExercise? {
        exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
    }
    /// Indices of exercises actually played (not skipped), in order.
    private var playableCount: Int { exercises.filter { !$0.skipped }.count }
    private var playedSoFar: Int { exercises.prefix(exerciseIndex).filter { !$0.skipped }.count + 1 }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .exercise: exerciseScreen.transition(.workoutPhase(reduceMotion: reduceMotion))
                case .rest: restScreen.transition(.workoutPhase(reduceMotion: reduceMotion))
                case .done: doneScreen.transition(.workoutPhase(reduceMotion: reduceMotion))
                }
            }
            .snappetAnimation(SnappetMotion.standard, value: phase)
            .safeAreaInset(edge: .top) { overallTimerHeader }
            .navigationTitle(session.routineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Minimize: leave the player without ending the workout (it keeps running in
                    // the background; the in-app banner brings it back).
                    Button { onMinimize() } label: { Label("Minimize", systemImage: "chevron.down") }
                        .accessibilityIdentifier("minimizeWorkout")
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Step back to fix a previously logged set.
                    if phase == .exercise && hasPrevious {
                        Button { goPrevious() } label: { Label("Previous set", systemImage: "chevron.left") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Pause / resume the live workout (relays to the watch + freezes the timers,
                    // overlay, and Live Activity).
                    if phase != .done {
                        Button { togglePause() } label: {
                            Label(isPaused ? "Resume" : "Pause",
                                  systemImage: isPaused ? "play.fill" : "pause.fill")
                        }
                        .accessibilityIdentifier("pauseWorkout")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // On the done screen the bottom "Finish" button is the single, clear exit —
                    // no redundant top-right "Done".
                    if phase != .done {
                        Button("End") { showingEnd = true }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            unit = defaultUnit; resumePosition()
            // Re-sync the local freeze with the live source (e.g. paused from the watch while
            // the player was minimized), then push the current state to the Live Activity.
            syncPausedDisplay(app.liveWorkout.isPaused)
            app.workoutNotifications.requestAuthorization()
            pushLiveActivity()
        }
        .onDisappear { timerTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // Returning to foreground: recompute remaining from the wall clock immediately
            // instead of waiting up to 200ms for the next tick.
            if phase == .active, self.phase == .rest, let end = restEndDate {
                restRemaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
            }
        }
        // Keep the Live Activity in sync as the player advances or HR changes. The overall
        // timer in the activity ticks on its own (anchored on startedAt); these updates only
        // refresh HR + the current exercise/set line.
        .onChange(of: phase) { _, _ in pushLiveActivity() }
        .onChange(of: exerciseIndex) { _, _ in pushLiveActivity() }
        .onChange(of: setIndex) { _, _ in pushLiveActivity() }
        .onChange(of: app.liveWorkout.latestHR) { _, _ in pushLiveActivity() }
        // React to pause changes from *either* device (the watch can pause too): freeze/unfreeze
        // the rest countdown + the displayed timer, then re-push so the Live Activity matches.
        .onChange(of: app.liveWorkout.isPaused) { _, paused in
            syncPausedDisplay(paused)
            pushLiveActivity()
        }
        .confirmationDialog("End this workout?", isPresented: $showingEnd, titleVisibility: .visible) {
            Button("Save & exit") { finish(saved: true) }
            Button("Discard (don't save)", role: .destructive) { finish(saved: false) }
            Button("Keep going", role: .cancel) {}
        }
        .confirmationDialog("Skip this exercise?", isPresented: $confirmingSkip, titleVisibility: .visible) {
            Button("Skip exercise", role: .destructive) { skipExercise() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Overall timer

    /// The overall workout timer = time since `session.startedAt`, shown alongside (and clearly
    /// distinct from) the per-set rest timer. Rendered with `Text(timerInterval:)` so SwiftUI
    /// self-updates it off the wall clock — correct across backgrounding with **no background
    /// CPU** (the same end-`Date` philosophy the rest timer uses). The accessibility value uses
    /// the pure `WorkoutLiveSnapshot.elapsedString` so the walkthrough test can read it
    /// deterministically (live-workout-studio A2).
    private var overallTimerHeader: some View {
        HStack(spacing: 8) {
            // Pause-aware (PR #31) icon, tinted with the Pulse workout accent when running (#30).
            Image(systemName: isPaused ? "pause.fill" : "stopwatch")
                .foregroundStyle(isPaused ? .yellow : SnappetColor.workout)
            Text("Total").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let frozen = displayElapsedAtPause {
                // Paused → freeze the displayed elapsed instead of letting the wall-clock timer tick.
                Text(WorkoutLiveSnapshot.elapsedString(frozen))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("PAUSED")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.yellow.opacity(0.25), in: Capsule())
                    .foregroundStyle(.yellow)
            } else {
                Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
        .snappetAnimation(SnappetMotion.standard, value: isPaused)
        .accessibilityIdentifier("overallWorkoutTimer")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Total workout time")
        .accessibilityValue(WorkoutLiveSnapshot.elapsedString(Date.now.timeIntervalSince(session.startedAt)))
    }

    // MARK: - Live Activity sync

    /// The current live snapshot — what the in-player timer + Live Activity should show right now.
    private var currentSnapshot: WorkoutLiveSnapshot {
        let hr = app.liveWorkout.latestHR.map { Int($0.rounded()) }
        let name: String
        let progress: String
        switch phase {
        case .done:
            name = "Workout complete"; progress = ""
        case .rest:
            name = "Resting"
            progress = nextSetLabel ?? ""
        case .exercise:
            if let ex = current {
                name = resolver.name(for: ex.exerciseId, override: ex.displayName)
                progress = "Set \(setIndex + 1) of \(ex.sets.count)"
            } else {
                name = session.routineName; progress = ""
            }
        }
        let profile = app.userProfile.profile
        let ready = RecoveryReadiness.evaluate(currentBpm: hr.map(Double.init),
                                               restBpm: profile.restingBound,
                                               maxBpm: profile.resolvedMaxHR).state == .ready
        return WorkoutLiveSnapshot(startedAt: session.startedAt, hrBpm: hr,
                                   exerciseName: name, setProgress: progress,
                                   paused: isPaused, recoveryReady: ready)
    }

    private func pushLiveActivity() {
        app.liveActivity.update(currentSnapshot)
    }

    // MARK: - Pause / resume

    /// Whether the live workout is currently paused (source of truth lives on the coordinator so
    /// the watch + Live Activity agree).
    private var isPaused: Bool { app.liveWorkout.isPaused }

    /// Toggle pause from the player's control. The coordinator relays it to the watch; the
    /// `onChange(isPaused)` handler does the local freeze/unfreeze so a watch-driven toggle takes
    /// the same path.
    private func togglePause() {
        if isPaused { app.liveWorkout.resume() } else { app.liveWorkout.pause() }
        Haptics.tap()
    }

    /// Reconcile the player's local UI with the live paused state: freeze/unfreeze the displayed
    /// elapsed and pause/resume the in-player rest countdown so the rest timer doesn't keep ticking
    /// (and firing) while the workout is paused.
    private func syncPausedDisplay(_ paused: Bool) {
        if paused {
            if displayElapsedAtPause == nil {
                displayElapsedAtPause = Date.now.timeIntervalSince(session.startedAt)
            }
            if phase == .rest { pauseRest() }
        } else {
            displayElapsedAtPause = nil
            if phase == .rest { resumeRest() }
        }
    }

    // MARK: - Exercise screen

    @ViewBuilder private var exerciseScreen: some View {
        if let ex = current {
            let exercise = resolver.exercise(id: ex.exerciseId)
            ScrollView {
                VStack(spacing: 20) {
                    liveMetricsOverlay
                    header(ex)

                    VStack(spacing: 4) {
                        Text(ex.discipline == .climb ? "Attempt \(setIndex + 1) of \(ex.sets.count)"
                                                     : "Set \(setIndex + 1) of \(ex.sets.count)")
                            .font(.title3.weight(.semibold))
                        Text(targetLine(ex))
                            .font(.subheadline).foregroundStyle(.secondary)
                        // What the user actually lifted last session — shown right where they
                        // decide today's weight (issue #73). Strength-only (the cross-session prefill is
                        // reps×weight); other disciplines drive their own prefill from the prescription.
                        if ex.discipline == .strength, let hint = lastSetHint?.hint {
                            Text(hint)
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("lastTimeHint")
                        }
                        setPips(ex)
                    }

                    disciplineInputs(ex)

                    Button { completeSet() } label: {
                        Text(completeButtonTitle(ex))
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                    .accessibilityIdentifier("completeSet")

                    Button(role: .destructive) { confirmingSkip = true } label: {
                        Label("Skip exercise", systemImage: "forward.end")
                    }
                    .font(.subheadline)

                    // M3: attach a photo/video to *this set* right here in the session, and see the
                    // clips already tagged to it. Keyed by exercise+set so the strip + its @Query
                    // re-scope as the user advances.
                    SetMediaStrip(session: session, exerciseID: ex.id, setIndex: setIndex)
                        .id("set-media-\(ex.id)-\(setIndex)")

                    if let exercise, !exercise.instructions.isEmpty {
                        instructions(exercise)
                    }
                }
                .padding()
            }
        } else {
            ProgressView()
        }
    }

    /// The A4 live-metrics overlay: a polished HR pill (❤️ bpm + zone color/label + source
    /// name) shown on the exercise and rest screens. Together with `overallTimerHeader` (A2,
    /// pinned to the top) and the rest countdown (rest screen), this gives the user the live
    /// HR + overall timer + rest timer at a glance — the user's "overlay fitness data along
    /// with current and overall workout timer" ask. When there's no HR sample it shows the
    /// source-aware "no source" status (reusing A1/A3's `liveStatusText`) instead of a fake
    /// zone, so a missing watch / band is obvious. No business logic here — bpm→zone mapping is
    /// the pure `HeartRateZone`; the view just renders it. (live-workout-studio A4)
    @ViewBuilder private var liveMetricsOverlay: some View {
        let bpm = app.liveWorkout.latestHR
        let profile = app.userProfile.profile
        LiveHRPill(bpm: bpm.map { Int($0.rounded()) },
                   zone: HeartRateZone.forBpm(bpm),
                   sourceName: app.liveWorkout.displayName,
                   noSourceText: liveStatusText,
                   contactLost: app.liveWorkout.isContactLost == true,
                   // "Rested enough for the next set?" — gated to a profile (Phase 4); `.unknown` hides.
                   readiness: RecoveryReadiness.evaluate(currentBpm: bpm,
                                                         restBpm: profile.restingBound,
                                                         maxBpm: profile.resolvedMaxHR))
            .accessibilityIdentifier("liveMetricsOverlay")
    }

    private var liveStatusText: String {
        // BLE band path: report the source-agnostic state (no watch concepts apply).
        if app.liveWorkout.activeKind == .ble {
            switch app.liveWorkout.state {
            case .unavailable: return "Turn on Bluetooth to use a heart-rate band"
            case .idle: return "Pick a heart-rate band in Settings"
            case .connecting: return "Connecting to \(app.liveWorkout.displayName)…"
            case .connected, .streaming: return "Waiting for heart rate…"
            }
        }
        // Apple-Watch path keeps its watch-specific wording (A1 behavior, unchanged).
        switch app.liveWorkout.connectionState {
        case .unsupported: return "No watch metrics on this device"
        case .inactive: return "Watch connecting…"
        case .active: return app.liveWorkout.isReachable
            ? "Watch ready — waiting for HR…" : "Open the workout on your watch"
        case .workoutRunning: return "Waiting for heart rate…"
        }
    }

    private func header(_ ex: SessionExercise) -> some View {
        VStack(spacing: 6) {
            Text("Exercise \(playedSoFar) of \(playableCount)")
                .font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.workout)
            Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                .font(.title2.bold()).multilineTextAlignment(.center)
        }
    }

    private func setPips(_ ex: SessionExercise) -> some View {
        HStack(spacing: 6) {
            ForEach(ex.sets.indices, id: \.self) { i in
                Circle()
                    .fill(ex.sets[i].completedAt != nil ? SnappetColor.workout
                          : (i == setIndex ? SnappetColor.workout.opacity(0.4) : Color(.systemGray4)))
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.top, 2)
        // Pip fill advances as sets complete — gentle cross-fade, gated by Reduce Motion.
        .snappetAnimation(SnappetMotion.standard, value: setIndex)
    }

    /// One shared focus across the reps/weight fields — the number pad has no return
    /// key, so the keypad Done toolbar is the only way to dismiss it (issue #82).
    @FocusState private var keypadFocused: Bool

    // MARK: - Discipline-aware input + labels (workout-redesign E4)

    /// The target/prescription line under the set count, per discipline.
    private func targetLine(_ ex: SessionExercise) -> String {
        let rest = ex.targetRestSeconds > 0 ? " · \(restText(ex.targetRestSeconds)) rest" : ""
        switch ex.discipline {
        case .strength:
            return "Target: \(ex.targetReps) reps" + rest
        case .climb:
            let grade = ex.climbGradeLabel.map { "\($0)" } ?? ex.climbType.label
            return "Target: \(grade)" + rest
        case .timed:
            if let spec = ex.timedSpec { return "Target: \(spec.summary)" + rest }
            return "Time your effort" + rest
        case .run:
            return "Log your run" + rest
        case .dance, .other:
            return "Time your effort" + rest
        }
    }

    /// The "Complete set" CTA title, per discipline (the last effort finishes the workout).
    private func completeButtonTitle(_ ex: SessionExercise) -> String {
        let last = isLastSetOfWorkout
        switch ex.discipline {
        case .climb:                    return last ? "Log attempt & finish" : "Log attempt"
        case .run:                      return last ? "Log run & finish" : "Log run"
        case .strength, .timed, .dance, .other:
            return last ? "Complete & finish" : "Complete set"
        }
    }

    /// The per-set input block, switched on the entity's discipline. Each reuses the freeform side's
    /// proven input vocabulary (the grade rail, the StopwatchView, the run distance+time fields) so a
    /// guided routine logs the SAME shape a freeform session does — the keystone parity. Strength keeps
    /// the original reps×weight keypad untouched.
    @ViewBuilder private func disciplineInputs(_ ex: SessionExercise) -> some View {
        switch ex.discipline {
        case .strength:          strengthInputs
        case .climb:             climbInputs
        case .timed, .dance, .other: timedInputs
        case .run:               runInputs
        }
    }

    /// Strength: the original reps × weight × unit keypad (unchanged behavior).
    private var strengthInputs: some View {
        HStack(spacing: 16) {
            field(title: "Reps", text: $repsText, keyboard: .numberPad, suffix: nil)
            field(title: "Weight", text: $weightText, keyboard: .decimalPad, suffix: unit.display)
            VStack(spacing: 4) {
                Text("Unit").font(.caption).foregroundStyle(.secondary)
                Picker("Unit", selection: $unit) {
                    ForEach(WeightUnit.allCases) { Text($0.display).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 96)
            }
        }
        .keypadDoneToolbar($keypadFocused)
    }

    /// Climb: a discrete scale-aware grade rail + an outcome segmented control (reuses the freeform
    /// climb vocabulary — `GradeScale.rungs` + the type-aware `KilterAscentStatus` relabels).
    private var climbInputs: some View {
        VStack(spacing: 14) {
            // Outcome (type-relabelled — boulder "Sent", a route "Redpoint").
            Picker("Outcome", selection: $climbStatus) {
                ForEach([KilterAscentStatus.flash, .sent, .project, .attempt], id: \.self) { st in
                    Text(climbType.statusLabel(st)).tag(st)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("player.climbOutcome")

            // The grade rail (the prescription pre-selects the prescribed grade; the user can adjust).
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Grade").font(.caption).foregroundStyle(.secondary)
                    Text(climbGrade).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.workout)
                        .accessibilityIdentifier("player.climbGradeValue")
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(climbScale.rungs, id: \.self) { rung in
                                gradeChip(rung, selected: rung == climbGrade) { climbGrade = rung }
                                    .id(rung)
                                    .accessibilityIdentifier("player.rung.\(rung)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: climbGrade) { _, g in withAnimation { proxy.scrollTo(g, anchor: .center) } }
                    .onAppear { proxy.scrollTo(climbGrade, anchor: .center) }
                }
            }
        }
    }

    /// Timed (and dance/other): the shared StopwatchView captures the effort duration. Count down from the
    /// prescribed hold when there is one (a `.countDown`/`.maxHang` spec), else count up.
    private var timedInputs: some View {
        VStack(spacing: 12) {
            StopwatchView(mode: timedStopwatchMode) { elapsed in
                capturedDuration = elapsed
            }
            if capturedDuration > 0 {
                Text("Captured: \(SetMeasure.formatDuration(capturedDuration))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.workout)
                    .accessibilityIdentifier("player.capturedDuration")
            }
        }
    }

    /// Run: manual distance + duration (pace derived), reusing the freeform run-leg vocabulary.
    private var runInputs: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                field(title: "Distance", text: $runDistanceText, keyboard: .decimalPad,
                      suffix: distanceUnit.display)
                field(title: "Min", text: $runMinutes, keyboard: .numberPad, suffix: nil)
                field(title: "Sec", text: $runSeconds, keyboard: .numberPad, suffix: nil)
            }
            .keypadDoneToolbar($keypadFocused)
            if let pace = runPacePreview {
                Text("Pace: \(pace)").font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("player.runPace")
            }
        }
    }

    /// The stopwatch mode for the current timed exercise: armed to a count-down when the prescription has a
    /// fixed work target, else a free count-up.
    private var timedStopwatchMode: StopwatchTiming.Mode {
        guard let ex = current else { return .countUp }
        if let spec = ex.timedSpec, !spec.mode.isStructured, spec.workSec > 0 {
            return .countDown(targetSec: Double(spec.workSec))
        }
        return .countUp
    }

    /// Parsed run distance in metres (accepts a decimal comma); nil when blank/non-positive.
    private var runDistanceMeters: Double? {
        let cleaned = runDistanceText.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite, v > 0, v < 100_000 else { return nil }
        return distanceUnit == .km ? v * 1000 : v * 1609.344
    }
    private var runDurationSec: Double {
        let m = Double(runMinutes) ?? 0, s = Double(runSeconds) ?? 0
        return max(0, m) * 60 + max(0, s)
    }
    private var runPacePreview: String? {
        guard let d = runDistanceMeters, d > 0, runDurationSec > 0 else { return nil }
        return SetMeasure.formatPace(secPerKm: runDurationSec / (d / 1000), unit: distanceUnit)
    }

    /// A grade-rail chip (matches AddClimbSheet's rung pill — fill + bold for the selected rung).
    private func gradeChip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? SnappetColor.workout : SnappetColor.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func field(title: String, text: Binding<String>, keyboard: UIKeyboardType, suffix: String?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("0", text: text)
                    .keyboardType(keyboard).multilineTextAlignment(.center)
                    .focused($keypadFocused)
                    .font(.title3.weight(.semibold)).frame(width: 64)
                if let suffix { Text(suffix).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: SnappetRadius.sm))
        }
    }

    private func instructions(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to").font(.headline)
            // Guide photos when the downloaded pack has them — no download CTA mid-workout.
            GuidePhotoStrip(exerciseId: exercise.id)
            ForEach(Array(exercise.instructions.prefix(4).enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(idx + 1)").font(.caption.bold()).foregroundStyle(SnappetColor.workout)
                    Text(step).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    // MARK: - Rest screen

    private var restScreen: some View {
        VStack(spacing: 28) {
            liveMetricsOverlay.padding(.horizontal)
            Spacer()
            Text("Rest").font(.title.bold())
            ZStack {
                Circle().stroke(Color(.systemGray5), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: restTotal > 0 ? CGFloat(restRemaining) / CGFloat(restTotal) : 0)
                    .stroke(SnappetColor.workout, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // The countdown sweep is a quiet linear tick; under Reduce Motion it snaps.
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: restRemaining)
                Text(timeString(restRemaining))
                    .font(.system(size: restTimerSize, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 220, height: 220)
            .background(flash ? SnappetColor.habits.opacity(0.25) : .clear)
            .clipShape(Circle())

            if let next = nextSetLabel {
                Text(next).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { skipRest() } label: {
                Label("Skip rest", systemImage: "forward.fill").font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered).tint(SnappetColor.workout).padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Done screen

    private var doneScreen: some View {
        let volumeKg = WorkoutMath.sessionVolumeKg(session)
        return VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: doneSealSize)).foregroundStyle(SnappetColor.workout)
                // Celebratory bounce on the completion seal; the trigger value is held constant
                // under Reduce Motion so the effect never fires.
                .symbolEffect(.bounce, value: reduceMotion ? 0 : doneBounce)
            Text("Workout Complete").font(.title.bold())
            Text(session.routineName).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                stat("\(durationMinutes)m", "Duration")
                stat("\(session.completedSetCount)", "Sets")
                stat("\(session.completedExerciseCount)", "Exercises")
            }
            if volumeKg > 0 {
                Text("Total volume: \(WorkoutMath.formatVolume(kg: volumeKg, unit: unit))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { finish(saved: true) } label: {
                Text("Finish").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(SnappetColor.workout).padding(.horizontal)
        }
        .padding()
        .onAppear { doneBounce += 1 }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var durationMinutes: Int { max(1, Int(session.duration / 60)) }
    private var isLastSetOfWorkout: Bool {
        guard let ex = current else { return true }
        let lastSet = setIndex >= ex.sets.count - 1
        let noMoreExercises = nextPlayableIndex(after: exerciseIndex) == nil
        return lastSet && noMoreExercises
    }
    private var nextSetLabel: String? {
        guard let ex = current else { return nil }
        if setIndex + 1 < ex.sets.count {
            return "Next: \(resolver.name(for: ex.exerciseId, override: ex.displayName)) · set \(setIndex + 2)"
        }
        if let n = nextPlayableIndex(after: exerciseIndex) {
            return "Next: \(resolver.name(for: exercises[n].exerciseId, override: exercises[n].displayName))"
        }
        return nil
    }

    // MARK: - Flow

    private func resumePosition() {
        // Jump to the first exercise/set without a completion timestamp.
        for (eIdx, ex) in exercises.enumerated() where !ex.skipped {
            if let sIdx = ex.sets.firstIndex(where: { $0.completedAt == nil }) {
                exerciseIndex = eIdx; setIndex = sIdx; phase = .exercise; prefillInputs(); return
            }
        }
        // Everything already logged.
        if exercises.contains(where: { !$0.skipped && $0.completedSetCount > 0 }) {
            phase = .done
        } else if let first = exercises.firstIndex(where: { !$0.skipped }) {
            exerciseIndex = first; setIndex = 0; prefillInputs()
        }
    }

    /// The cross-session "last time" for an exercise (issue #73) — nil with no usable history.
    private func lastTime(_ ex: SessionExercise) -> LastSetLookup.LastTime? {
        LastSetLookup.lastTime(exerciseId: ex.exerciseId, history: history)
    }

    private func prefillInputs() {
        guard let ex = current else { return }
        // Reset the per-set transient inputs every advance so one discipline's entry never bleeds into the
        // next set/exercise (workout-redesign E4).
        capturedDuration = 0
        runDistanceText = ""; runMinutes = ""; runSeconds = ""
        rpe = 0
        switch ex.discipline {
        case .strength:
            prefillStrength(ex)
        case .climb:
            // Seed the grade rail from the prescription / the previous attempt's grade so the warm path is
            // "pick outcome → log". The outcome defaults to a send.
            climbType = ex.climbType
            climbScale = ex.climbGradeScale
            let previousGrade = ex.sets.prefix(setIndex).last { $0.completedAt != nil }?.climbGradeLabel
            climbGrade = previousGrade ?? ex.climbGradeLabel ?? ex.climbGradeScale.defaultGrade
            climbStatus = .sent
        case .timed, .run, .dance, .other:
            break   // these capture live (stopwatch / typed fields); nothing to pre-fill
        }
    }

    /// The original strength prefill: previous logged set → cross-session "last time" → routine target.
    private func prefillStrength(_ ex: SessionExercise) {
        lastSetHint = lastTime(ex)
        let previous = ex.sets.prefix(setIndex).last(where: { $0.completedAt != nil })
        if let previous {
            repsText = previous.actualReps.map(String.init) ?? leadingNumber(ex.targetReps)
            weightText = previous.actualWeight.map(SetMeasure.formatWeight) ?? ""
            unit = previous.weightUnit ?? unit
        } else if let last = lastSetHint {
            repsText = last.reps.map(String.init) ?? leadingNumber(ex.targetReps)
            weightText = last.weight.map(SetMeasure.formatWeight) ?? ""
            unit = last.unit ?? ex.targetWeightUnit ?? defaultUnit
        } else {
            repsText = leadingNumber(ex.targetReps)
            weightText = ex.targetWeight.map(SetMeasure.formatWeight) ?? ""
            unit = ex.targetWeightUnit ?? defaultUnit
        }
    }

    private func completeSet() {
        guard let ex0 = current else { return }
        // Build the logged set from the right axes for this discipline (workout-redesign E4): a climb logs
        // grade+outcome, a timed/dance/other set its captured duration, a run distance+duration (+optional
        // RPE), strength its reps×weight (unchanged). `completedAt` stamps it done for every discipline.
        session.exercises[exerciseIndex].sets[setIndex] = loggedSet(for: ex0)
        persist()
        Haptics.success()

        let ex = session.exercises[exerciseIndex]
        if setIndex + 1 < ex.sets.count {
            // More sets in this exercise → rest, then advance.
            if ex.targetRestSeconds > 0 { startRest(ex.targetRestSeconds) }
            else { setIndex += 1; prefillInputs() }
        } else {
            advanceExercise()
        }
    }

    /// Compose the `SetLog` for the current set from the active input fields, per discipline. Pure-ish
    /// assembly (the parsing funnels through `SetMeasure`/the run parser); the only side input is `Date.now`.
    private func loggedSet(for ex: SessionExercise) -> SetLog {
        switch ex.discipline {
        case .strength:
            return SetLog(actualReps: SetMeasure.parseReps(repsText),
                          actualWeight: SetMeasure.parseWeight(weightText),
                          weightUnit: unit, completedAt: .now,
                          durationSec: capturedDuration > 0 ? capturedDuration : nil,
                          rpe: rpe > 0 ? rpe : nil)
        case .climb:
            return SetLog(completedAt: .now,
                          durationSec: capturedDuration > 0 ? capturedDuration : nil,
                          climbGradeLabel: climbGrade.isEmpty ? ex.climbGradeLabel : climbGrade,
                          climbStatusRaw: climbStatus.rawValue, climbAttempts: 1)
        case .run:
            return SetLog(completedAt: .now,
                          durationSec: runDurationSec > 0 ? runDurationSec : nil,
                          distanceMeters: runDistanceMeters,
                          rpe: rpe > 0 ? rpe : nil)
        case .timed, .dance, .other:
            return SetLog(completedAt: .now,
                          durationSec: capturedDuration > 0 ? capturedDuration : nil,
                          rpe: rpe > 0 ? rpe : nil)
        }
    }

    private func advanceExercise() {
        if let next = nextPlayableIndex(after: exerciseIndex) {
            exerciseIndex = next; setIndex = 0; phase = .exercise; prefillInputs()
        } else {
            phase = .done
        }
    }

    private func skipExercise() {
        session.exercises[exerciseIndex].skipped = true
        persist()
        advanceExercise()
    }

    private func nextPlayableIndex(after index: Int) -> Int? {
        let next = (index + 1..<exercises.count).first { !exercises[$0].skipped }
        return next
    }

    // MARK: - Step back (edit a previous set)

    private var hasPrevious: Bool {
        if setIndex > 0 { return true }
        return previousPlayableIndex(before: exerciseIndex) != nil
    }

    private func previousPlayableIndex(before index: Int) -> Int? {
        (0..<index).last { !exercises[$0].skipped }
    }

    /// Move back one set (or to the last set of the previous played exercise) and prefill it with
    /// what was logged, so the user can correct a mistake. Re-completing it advances forward again.
    private func goPrevious() {
        if setIndex > 0 {
            setIndex -= 1
        } else if let prev = previousPlayableIndex(before: exerciseIndex) {
            exerciseIndex = prev
            setIndex = max(0, exercises[prev].sets.count - 1)
        } else {
            return
        }
        phase = .exercise
        prefillEditing()
    }

    /// Prefill inputs from the current set's own log (when stepping back to edit); otherwise fall
    /// back to the normal forward prefill.
    private func prefillEditing() {
        guard let ex = current, ex.sets.indices.contains(setIndex) else { prefillInputs(); return }
        let set = ex.sets[setIndex]
        guard set.completedAt != nil else { prefillInputs(); return }
        // Restore the discipline's logged values so the user can correct a previously-logged effort.
        capturedDuration = set.durationSec ?? 0
        rpe = set.rpe ?? 0
        switch ex.discipline {
        case .strength:
            lastSetHint = lastTime(ex)
            repsText = set.actualReps.map(String.init) ?? ""
            weightText = set.actualWeight.map(SetMeasure.formatWeight) ?? ""
            unit = set.weightUnit ?? unit
        case .climb:
            climbType = ex.climbType
            climbScale = ex.climbGradeScale
            climbGrade = set.climbGradeLabel ?? ex.climbGradeLabel ?? ex.climbGradeScale.defaultGrade
            climbStatus = set.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:)) ?? .sent
        case .run:
            runDistanceText = (set.distanceMeters).map { distanceUnit == .km ? Self.trimNum($0 / 1000)
                                                                            : Self.trimNum($0 / 1609.344) } ?? ""
            let total = Int((set.durationSec ?? 0).rounded())
            runMinutes = total > 0 ? String(total / 60) : ""
            runSeconds = total > 0 ? String(total % 60) : ""
        case .timed, .dance, .other:
            break   // capturedDuration restored above; the stopwatch starts fresh on re-log
        }
    }

    /// A decimal trimmed of trailing zeros for the run distance field (5.20 → "5.2", 5.00 → "5").
    private static func trimNum(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s
    }

    // MARK: - Rest timer

    private func startRest(_ seconds: Int) {
        restTotal = seconds
        restRemaining = seconds
        phase = .rest
        beginRestCountdown(from: seconds)
    }

    /// (Re)anchor the rest countdown to finish `seconds` from now and (re)schedule the background
    /// "rest complete" notification, so the rest still alerts the user if the player is minimized
    /// or the phone is locked. Shared by the initial start and by resume-after-pause.
    private func beginRestCountdown(from seconds: Int) {
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndDate = end
        app.workoutNotifications.scheduleRestComplete(after: TimeInterval(seconds), nextUp: nextSetLabel)
        runRestLoop()
    }

    private func runRestLoop() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                guard let end = restEndDate else { return }
                let remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
                restRemaining = remaining
                if remaining <= 0 { break }
            }
            await restFinished()
        }
    }

    /// Freeze the rest countdown while paused: stop the loop, drop the wall-clock anchor (so
    /// `restRemaining` holds), and cancel the scheduled notification so it can't fire mid-pause.
    private func pauseRest() {
        timerTask?.cancel()
        restEndDate = nil
        app.workoutNotifications.clear()
    }

    /// Resume the rest countdown from the frozen `restRemaining`.
    private func resumeRest() {
        guard restRemaining > 0 else { advanceAfterRest(); return }
        beginRestCountdown(from: restRemaining)
    }

    @MainActor private func restFinished() async {
        restEndDate = nil
        // Completed in-app → the flash + haptics are the cue; cancel the background notification
        // so it doesn't also fire.
        app.workoutNotifications.clear()
        Haptics.success()
        flash = true
        try? await Task.sleep(for: .milliseconds(350))
        flash = false
        advanceAfterRest()
    }

    private func skipRest() {
        timerTask?.cancel()
        restEndDate = nil
        app.workoutNotifications.clear()
        Haptics.tap()
        advanceAfterRest()
    }

    private func advanceAfterRest() {
        setIndex += 1
        phase = .exercise
        prefillInputs()
    }

    // MARK: - Finish

    private func finish(saved: Bool) {
        timerTask?.cancel()
        app.workoutNotifications.clear()
        // Don't persist an empty workout — if nothing was logged, discard regardless of the exit chosen.
        onClose(saved && session.completedSetCount > 0)
    }

    private func persist() { try? context.save() }

    // MARK: - Helpers

    private func leadingNumber(_ reps: String) -> String {
        let digits = reps.prefix { $0.isNumber }
        return digits.isEmpty ? "" : String(digits)
    }
    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The live heart-rate pill rendered by the player's `liveMetricsOverlay` (A4). A thin,
/// state-free view: it's handed an already-computed bpm + `HeartRateZone` + source name (the
/// bpm→zone mapping is the pure, unit-tested `HeartRateZone`), so it contains no business
/// logic. With a sample it shows ❤️ + bpm tinted by the zone color, the short zone label, and
/// the source name; with no sample it shows the source-aware "no source" status text.
private struct LiveHRPill: View {
    let bpm: Int?
    let zone: HeartRateZone
    let sourceName: String
    /// Source-aware status when there's no live HR (e.g. "Open the workout on your watch").
    let noSourceText: String
    /// Band reports the sensor lost skin/strap contact → show an "adjust strap" hint (the bpm is
    /// momentarily frozen at the last good value). Always `false` for sources that can't report it.
    var contactLost: Bool = false
    /// Live recovery-ready state (Phase 4); a "Recovered" chip shows only when `.ready`, hidden for
    /// `.recovering` / `.unknown` (no profile) so HR-less / no-profile sessions are unchanged.
    var readiness: RecoveryReadiness = .unknown

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .foregroundStyle(bpm == nil ? Color.secondary : zone.color)
                // The heart pulses in time with a live sample; suppressed under Reduce Motion.
                .symbolEffect(.pulse, isActive: bpm != nil && !reduceMotion)
            if let bpm {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(bpm)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(zone.color)
                        .contentTransition(.numericText())
                    Text("bpm").font(.caption).foregroundStyle(.secondary)
                }
                Text(zone.pillLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(zone.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(zone.color)
                if contactLost {
                    Label("Adjust strap", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("hrContactLost")
                }
                if readiness.state == .ready {
                    Label("Recovered", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("hrRecoveryReady")
                }
                Spacer(minLength: 4)
                Text(sourceName)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(noSourceText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: Capsule())
        // Cross-fade the bpm/zone tint + label as the training zone changes (issue #30 §5.6).
        .snappetAnimation(SnappetMotion.standard, value: zone)
        .snappetAnimation(SnappetMotion.standard, value: bpm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bpm == nil ? "Heart rate"
            : "Heart rate \(bpm!) beats per minute, \(zone.label) zone, source \(sourceName)")
        .accessibilityValue(bpm == nil ? noSourceText
            : (contactLost ? "\(bpm!) bpm, adjust strap" : "\(bpm!) bpm"))
    }
}

