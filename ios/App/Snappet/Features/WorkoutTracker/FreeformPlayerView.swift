import SwiftUI
import SwiftData
import HighlightEngine

/// A **freeform / dynamic** session player: unlike the guided `WorkoutPlayerView` (which walks a fixed
/// routine set-by-set), this is a grow-as-you-go logbook — add exercises and sets/attempts on the fly,
/// of any `SetKind` (reps & weight, timed, or climb attempts). Used for routineless sessions
/// (`routineID == nil`), e.g. an ad-hoc gym lifting session or a bouldering session where you don't
/// know the next climb. (dynamic-sessions D3/D5; reworked as a discoverable canvas in issue #158)
///
/// Kept separate from `WorkoutPlayerView` on purpose: the guided flow is device-verified and tightly
/// coupled to reps×weight + a fixed index walk; a list-based logbook is the right shape for "add as you
/// go" and avoids destabilizing it.
///
/// **Canvas + command bar (issue #158 §A):** the empty state offers three discoverable type cards
/// (Lifting / Climbing / Timed); an always-present `Menu` (`freeform.addExercise`) adds more once
/// underway; the title is inline-editable; and a persistent bottom command bar
/// (`safeAreaInset(edge: .bottom)`) carries the wall-clock timer, a compact live-HR chip, and the
/// always-available Finish — replacing the redundant toolbar "End" so there's one consistent exit.
struct FreeformPlayerView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    /// Prior completed sessions — feeds the "Last time…" prefill/hint (§B) and the milestone check (§D).
    let history: [WorkoutSession]
    let defaultUnit: WeightUnit
    /// Close + report whether to keep (finish / save & exit) or discard the session.
    let onClose: (_ saved: Bool) -> Void
    /// Dismiss without ending — the session stays active (background/minimize ask).
    let onMinimize: () -> Void
    /// Finish + save, then open the completed session's detail (the completion screen's "View detail").
    let onViewDetail: (WorkoutSession) -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app

    @State private var pickingLift = false
    @State private var logging: LogTarget?
    // Naming a free-flow climb (workout-with-timer PR 5): tapping "Climbing" in the add menu first asks
    // for a custom climb name (e.g. "Cave Project", "Blue V4") so per-attempt logging groups under the
    // named climb instead of a fixed "Climbing". Empty/whitespace falls back to "Climbing".
    @State private var namingClimb = false
    @State private var climbNameDraft = ""

    private var unit: WeightUnit { defaultUnit }

    var body: some View {
        NavigationStack {
            List {
                titleSection
                if session.exercises.isEmpty { emptyStateHero }
                ForEach(session.exercises) { ex in exerciseSection(ex) }
                addExerciseSection
            }
            .navigationTitle(session.routineName)
            .navigationBarTitleDisplayMode(.inline)
            // The persistent command bar (§A): wall-clock timer · compact HR chip · always-on Finish.
            // Reuses the module's `safeAreaInset(edge: .bottom)` banner idiom.
            .safeAreaInset(edge: .bottom) { commandBar }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onMinimize() } label: { Label("Minimize", systemImage: "chevron.down") }
                        .accessibilityIdentifier("minimizeWorkout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { togglePause() } label: {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    }
                    .accessibilityIdentifier("pauseWorkout")
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $pickingLift) {
            ExercisePickerView(resolver: resolver) { picked in addLifting(picked) }
        }
        .sheet(item: $logging) { target in
            LogSetSheet(kind: target.kind, unit: unit) { log in appendLog(log, toExerciseID: target.exerciseID) }
        }
        // Name this climb (workout-with-timer PR 5): the typed name is the section header + persists on the
        // SessionExercise's `displayName`; a blank/whitespace entry falls back to "Climbing" via the pure
        // `SetMeasure.climbName`. The TextField is a leaf control with its own id so XCUITest can fill it
        // — no identifier on a composite (the PR 2/3/4 a11y lesson).
        .alert("Name this climb", isPresented: $namingClimb) {
            TextField("Climb name (e.g. Cave Project)", text: $climbNameDraft)
                .accessibilityIdentifier("freeform.climbName")
            Button("Add") { addExercise(kind: .climbAttempt, name: SetMeasure.climbName(climbNameDraft)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Group every attempt under a name, or leave blank for \"Climbing\".")
        }
        .onAppear {
            app.workoutNotifications.requestAuthorization()
            pushLiveActivity()
        }
        // Keep the Live Activity (Lock Screen / Dynamic Island) in sync with the freeform session:
        // live HR and the paused state push as they change. The overall timer self-ticks off
        // `startedAt`; these refresh HR + the exercise line + the paused flag. Mirrors `WorkoutPlayerView`.
        .onChange(of: app.liveWorkout.latestHR) { _, _ in pushLiveActivity() }
        .onChange(of: app.liveWorkout.isPaused) { _, _ in pushLiveActivity() }
    }

    // MARK: - Sections

    /// Inline-editable session title (§A). Commits to `WorkoutSession.routineName` (default "Quick
    /// session") and pushes the Live Activity so the Lock-Screen label updates. A leaf TextField.
    private var titleSection: some View {
        Section {
            TextField("Session name", text: $session.routineName)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .onSubmit { persist(); pushLiveActivity() }
                .accessibilityIdentifier("freeform.sessionTitle")
        }
    }

    /// Discoverable empty-state canvas (§A): three labelled type cards instead of a buried menu. They
    /// call the same mutators as the `freeform.addExercise` menu items; their accessibility labels are
    /// distinct from the menu-item labels so XCUITest queries stay unambiguous.
    private var emptyStateHero: some View {
        Section {
            VStack(spacing: 12) {
                Text("Start your session").font(.headline)
                Text("Pick what you're tracking — add more as you go.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    typeCard("Lifting", symbol: "dumbbell.fill",
                             id: "freeform.cardLifting", accLabel: "Start lifting") { pickingLift = true }
                    typeCard("Climbing", symbol: "figure.climbing",
                             id: "freeform.cardClimbing", accLabel: "Start climbing") {
                        climbNameDraft = ""; namingClimb = true
                    }
                    typeCard("Timed", symbol: "timer",
                             id: "freeform.cardTimed", accLabel: "Start a timed exercise") {
                        addExercise(kind: .duration, name: "Timed exercise")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func typeCard(_ title: String, symbol: String, id: String,
                          accLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(SnappetColor.workout)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .snappetTile()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(accLabel)
    }

    private func exerciseSection(_ ex: SessionExercise) -> some View {
        Section {
            ForEach(Array(ex.sets.enumerated()), id: \.offset) { i, set in
                HStack {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    Text(SetMeasure.summary(set, kind: ex.kind, unit: unit))
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .accessibilityIdentifier("freeform.setRow")
            }
            .onDelete { offsets in deleteSets(ex, at: offsets) }

            Button {
                logging = LogTarget(exerciseID: ex.id, kind: ex.kind)
            } label: {
                Label(ex.kind.addLabel, systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("freeform.addSet")

            // One-tap repeat of the most recent set — duplicates it (all kind-specific fields, fresh
            // completedAt) without opening the sheet. Only shown once there's a set to repeat. A sibling
            // leaf Button (NOT wrapped in a composite) so its accessibilityIdentifier stays queryable.
            if !ex.sets.isEmpty {
                Button {
                    repeatLastSet(ex)
                } label: {
                    Label("Repeat set", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("freeform.repeatSet")
            }
        } header: {
            HStack {
                Label(resolver.name(for: ex.exerciseId, override: ex.displayName), systemImage: ex.kind.symbol)
                Spacer()
                Menu {
                    Button(role: .destructive) { removeExercise(ex) } label: {
                        Label("Remove exercise", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var addExerciseSection: some View {
        Section {
            Menu {
                Button { pickingLift = true } label: { Label("Lifting exercise", systemImage: "dumbbell.fill") }
                Button { climbNameDraft = ""; namingClimb = true } label: {
                    Label("Climbing", systemImage: "figure.climbing")
                }
                Button { addExercise(kind: .duration, name: "Timed exercise") } label: {
                    Label("Timed exercise", systemImage: "timer")
                }
            } label: {
                Label("Add exercise", systemImage: "plus")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .accessibilityIdentifier("freeform.addExercise")
        }
    }

    /// The persistent bottom command bar (§A): wall-clock total timer · compact live-HR chip · the
    /// always-available Finish. The timer/HR are non-interactive labels (a labelled composite is fine —
    /// the leaf-only rule is about interactive controls); Finish keeps its `freeform.finish` id.
    private var commandBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "pause.fill" : "stopwatch")
                    .foregroundStyle(isPaused ? .yellow : SnappetColor.workout)
                Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            .accessibilityIdentifier("overallWorkoutTimer")

            Spacer(minLength: 8)

            if let bpm = app.liveWorkout.latestHR {
                Label("\(Int(bpm.rounded()))", systemImage: "heart.fill")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(HeartRateZone.forBpm(bpm).color)
                    .accessibilityIdentifier("freeform.hrChip")
            }

            Button { finish(saved: true) } label: {
                Text("Finish").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnappetColor.workout)
            .accessibilityIdentifier("freeform.finish")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Mutations

    private func indexOf(_ ex: SessionExercise) -> Int? {
        session.exercises.firstIndex { $0.id == ex.id }
    }

    private func addLifting(_ exercises: [Exercise]) {
        for ex in exercises {
            session.exercises.append(SessionExercise(
                exerciseId: ex.id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                sets: [], displayName: nil, kindRaw: SetKind.repsWeight.rawValue))
        }
        persist()
        pushLiveActivity()   // the new exercise becomes the current one → refresh the Lock Screen label
    }

    private func addExercise(kind: SetKind, name: String) {
        session.exercises.append(SessionExercise(
            exerciseId: "adhoc-\(kind.rawValue)", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: [], displayName: name, kindRaw: kind.rawValue))
        persist()
        pushLiveActivity()
    }

    private func removeExercise(_ ex: SessionExercise) {
        guard let idx = indexOf(ex) else { return }
        session.exercises.remove(at: idx)
        persist()
        pushLiveActivity()   // the current (last) exercise may have changed
    }

    private func appendLog(_ log: SetLog, toExerciseID id: UUID) {
        guard let idx = session.exercises.firstIndex(where: { $0.id == id }) else { return }
        var entry = log
        entry.completedAt = .now
        session.exercises[idx].sets.append(entry)
        persist()
        pushLiveActivity()
        Haptics.success()
    }

    /// One-tap "Repeat set": append a copy of `ex`'s most recent set (all kind-specific fields via the
    /// pure `SetMeasure.duplicate`) WITHOUT opening `LogSetSheet`, then reuse the same append+persist+haptic
    /// path the sheet commits through — `appendLog` stamps the fresh `completedAt`. No-op when the exercise
    /// has no sets (the control is hidden in that case). (workout-with-timer PR 3)
    private func repeatLastSet(_ ex: SessionExercise) {
        guard let last = ex.sets.last else { return }
        appendLog(SetMeasure.duplicate(last), toExerciseID: ex.id)
    }

    private func deleteSets(_ ex: SessionExercise, at offsets: IndexSet) {
        guard let idx = indexOf(ex) else { return }
        session.exercises[idx].sets.remove(atOffsets: offsets)
        persist()
    }

    private func finish(saved: Bool) {
        onClose(saved && session.completedSetCount > 0)
    }

    private func persist() { try? context.save() }

    // MARK: - Live Activity

    /// Push the current freeform state to the Live Activity so the Lock Screen / Dynamic Island show
    /// live HR, the exercise being worked (the most recently added), and the paused state — instead of
    /// the stale seed. The exercise label is the latest non-skipped exercise (a freeform logbook has no
    /// fixed cursor); `setProgress` stays empty since there's no "Set N of M" target. No-op where Live
    /// Activities are unavailable; the controller diffs/throttles so a ~1 Hz HR stream is rate-limited.
    private func pushLiveActivity() {
        let current = session.exercises.last { !$0.skipped }
        let name = current.map { resolver.name(for: $0.exerciseId, override: $0.displayName) } ?? "Workout"
        let profile = app.userProfile.profile
        let ready = RecoveryReadiness.evaluate(currentBpm: app.liveWorkout.latestHR,
                                               restBpm: profile.restingBound,
                                               maxBpm: profile.resolvedMaxHR).state == .ready
        app.liveActivity.update(WorkoutLiveSnapshot(
            startedAt: session.startedAt,
            hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
            exerciseName: name,
            setProgress: "",
            paused: app.liveWorkout.isPaused,
            recoveryReady: ready))
    }

    // MARK: - Pause

    private var isPaused: Bool { app.liveWorkout.isPaused }
    private func togglePause() {
        if isPaused { app.liveWorkout.resume() } else { app.liveWorkout.pause() }
        Haptics.tap()
    }
}

/// Which exercise a new set/attempt is being logged into (drives the `LogSetSheet`).
private struct LogTarget: Identifiable {
    let exerciseID: UUID
    let kind: SetKind
    var id: UUID { exerciseID }
}

/// How a `.duration` set's seconds are entered: time it live with the stopwatch (default), or type
/// minutes/seconds. Both write the same `minutes`/`seconds` state the save path reads. (workout-with-timer PR 2)
private enum DurationInputMode: String, CaseIterable, Identifiable {
    case timer, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .timer: return "Timer"
        case .manual: return "Manual"
        }
    }
}

/// A focused sheet to log one set/attempt, with fields that adapt to the exercise's `SetKind`. Builds a
/// `SetLog` and hands it back; the player stamps `completedAt` and appends it.
private struct LogSetSheet: View {
    let kind: SetKind
    let unit: WeightUnit
    let onAdd: (SetLog) -> Void

    @Environment(\.dismiss) private var dismiss

    // reps & weight
    @State private var reps = ""
    @State private var weight = ""
    @State private var unitSel: WeightUnit
    // duration — Timer (live `StopwatchView`) or Manual (Min/Sec fields); a Stop capture fills the same
    // `minutes`/`seconds` the Manual fields write, so `build()` stays one expression. (workout-with-timer PR 2)
    @State private var durationMode: DurationInputMode = .timer
    @State private var timerRunning = false
    @State private var minutes = ""
    @State private var seconds = ""
    // climb
    @State private var grade = ""
    @State private var status: KilterAscentStatus = .sent
    @State private var tries = 1
    // climb — OPTIONAL per-attempt timer (workout-with-timer PR 4): off by default so quick logging is
    // unchanged. When on, a StopwatchView(.countUp) Stop capture fills `climbDurationSec`, which `build()`
    // writes into the (otherwise-unused-for-climbs) SetLog.durationSec. `climbTimerRunning` gates the
    // disclosure toggle while running so it can't be collapsed mid-run (tearing down the timer without a
    // Stop, silently dropping the capture — the timed-set lesson).
    @State private var climbTimed = false
    @State private var climbTimerRunning = false
    @State private var climbDurationSec: Double?

    init(kind: SetKind, unit: WeightUnit, onAdd: @escaping (SetLog) -> Void) {
        self.kind = kind
        self.unit = unit
        self.onAdd = onAdd
        _unitSel = State(initialValue: unit)
    }

    @FocusState private var keypadFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .repsWeight:
                    TextField("Reps", text: $reps).keyboardType(.numberPad)
                        .focused($keypadFocused)
                        .accessibilityIdentifier("logset.reps")
                    HStack {
                        TextField("Weight", text: $weight).keyboardType(.decimalPad)
                            .focused($keypadFocused)
                            .accessibilityIdentifier("logset.weight")
                        Picker("Unit", selection: $unitSel) {
                            ForEach(WeightUnit.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 110).labelsHidden()
                    }
                case .duration:
                    Picker("Input", selection: $durationMode) {
                        ForEach(DurationInputMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    // Lock the mode while the stopwatch runs: switching to Manual would remove the
                    // StopwatchView, whose onDisappear cancels the ticker without a Stop — silently
                    // dropping the capture. The user must Stop first (onStop fills Min/Sec).
                    .disabled(timerRunning)
                    .accessibilityIdentifier("logset.durationMode")
                    switch durationMode {
                    case .timer:
                        // Press Start → do the hold → Stop captures the elapsed seconds into the same
                        // minutes/seconds the save path reads (PR 1's StopwatchView, first real consumer).
                        StopwatchView(mode: .countUp) { elapsed in
                            let split = SetMeasure.splitDuration(elapsed)
                            minutes = split.minutes
                            seconds = split.seconds
                        } onRunningChange: { timerRunning = $0 }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        // NOTE: no .accessibilityIdentifier on the StopwatchView itself — on iOS 26 that
                        // collapses the composite view into one accessibility element and hides its inner
                        // `stopwatch.toggle` button from XCUITest. The test queries the child ids directly.
                    case .manual:
                        HStack {
                            TextField("Min", text: $minutes).keyboardType(.numberPad)
                                .focused($keypadFocused)
                            Text(":").foregroundStyle(.secondary)
                            TextField("Sec", text: $seconds).keyboardType(.numberPad)
                                .focused($keypadFocused)
                        }
                        .accessibilityIdentifier("logset.duration")
                    }
                case .climbAttempt:
                    TextField("Grade (e.g. V4, 6c)", text: $grade)
                        .accessibilityIdentifier("logset.grade")
                    Picker("Outcome", selection: $status) {
                        ForEach(KilterAscentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("Attempts: \(tries)", value: $tries, in: 1...50)
                    // Optional: time how long the attempt took (the climb-side analogue of the timed-set
                    // timer, PR 2). Off by default → existing quick-logging is unchanged; the leaf Toggle
                    // is locked while the stopwatch runs so it can't tear the timer down without a Stop.
                    Toggle("Time the attempt", isOn: $climbTimed)
                        .disabled(climbTimerRunning)
                        .accessibilityIdentifier("logset.climbTimerToggle")
                    if climbTimed {
                        // Stop captures the elapsed seconds into `climbDurationSec`, which `build()` writes
                        // into SetLog.durationSec (the count-up StopwatchView from PR 1; same consumer
                        // shape as the timed-set Timer mode). NOTE: no .accessibilityIdentifier on the
                        // StopwatchView itself — on iOS 26 that collapses the composite into one element
                        // and hides its inner `stopwatch.toggle`; the test queries the child ids directly.
                        StopwatchView(mode: .countUp) { elapsed in
                            climbDurationSec = elapsed > 0 ? elapsed : nil
                        } onRunningChange: { climbTimerRunning = $0 }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(kind.addLabel)
            .keypadDoneToolbar($keypadFocused)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(build()); dismiss() }
                        .disabled(!SetMeasure.hasInput(build(), kind: kind))
                        .accessibilityIdentifier("logset.add")
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func build() -> SetLog {
        switch kind {
        case .repsWeight:
            return SetLog(actualReps: Int(reps.trimmingCharacters(in: .whitespaces)),
                          actualWeight: Double(weight.replacingOccurrences(of: ",", with: ".")
                            .trimmingCharacters(in: .whitespaces)),
                          weightUnit: unitSel)
        case .duration:
            let total = (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0)
            return SetLog(durationSec: total > 0 ? total : nil)
        case .climbAttempt:
            let g = grade.trimmingCharacters(in: .whitespaces)
            // Reuse `durationSec` for the optional per-attempt time (PR 4): nil unless the timer was used
            // and captured a non-zero hold, so untimed attempts log exactly as before.
            return SetLog(durationSec: climbTimed ? climbDurationSec : nil,
                          climbGradeLabel: g.isEmpty ? nil : g,
                          climbStatusRaw: status.rawValue, climbAttempts: tries)
        }
    }
}
