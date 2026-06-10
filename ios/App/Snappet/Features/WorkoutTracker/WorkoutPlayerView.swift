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

    enum Phase { case exercise, rest, done }
    @State private var phase: Phase = .exercise
    @State private var exerciseIndex = 0
    @State private var setIndex = 0

    // Per-set input.
    @State private var repsText = ""
    @State private var weightText = ""
    @State private var unit: WeightUnit = .kg

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
                case .exercise: exerciseScreen.transition(.workoutPhase)
                case .rest: restScreen.transition(.workoutPhase)
                case .done: doneScreen.transition(.workoutPhase)
                }
            }
            .animation(Motion.content, value: phase)
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
        .animation(.snappyNav, value: isPaused)
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
                        Text("Set \(setIndex + 1) of \(ex.sets.count)")
                            .font(.title3.weight(.semibold))
                        Text("Target: \(ex.targetReps) reps" + (ex.targetRestSeconds > 0
                             ? " · \(restText(ex.targetRestSeconds)) rest" : ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                        setPips(ex)
                    }

                    inputs

                    Button { completeSet() } label: {
                        Text(isLastSetOfWorkout ? "Complete & finish" : "Complete set")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(SnappetColor.workout)

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

    private var inputs: some View {
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
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
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
            Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(SnappetColor.workout)
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

    private func prefillInputs() {
        guard let ex = current else { return }
        // Prefer the previous logged set in this exercise; fall back to the routine target.
        let previous = ex.sets.prefix(setIndex).last(where: { $0.completedAt != nil })
        if let previous {
            repsText = previous.actualReps.map(String.init) ?? leadingNumber(ex.targetReps)
            weightText = previous.actualWeight.map(Self.formatWeight) ?? ""
            unit = previous.weightUnit ?? unit
        } else {
            repsText = leadingNumber(ex.targetReps)
            weightText = ex.targetWeight.map(Self.formatWeight) ?? ""
            unit = ex.targetWeightUnit ?? defaultUnit
        }
    }

    private func completeSet() {
        guard current != nil else { return }
        let reps = Int(repsText.trimmingCharacters(in: .whitespaces))
        let weight = Double(weightText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        session.exercises[exerciseIndex].sets[setIndex] = SetLog(
            actualReps: reps, actualWeight: weight, weightUnit: unit, completedAt: .now)
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
        if set.completedAt != nil {
            repsText = set.actualReps.map(String.init) ?? ""
            weightText = set.actualWeight.map(Self.formatWeight) ?? ""
            unit = set.weightUnit ?? unit
        } else {
            prefillInputs()
        }
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
    private static func formatWeight(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
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

