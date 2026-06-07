import SwiftUI
import SwiftData

/// A **freeform / dynamic** session player: unlike the guided `WorkoutPlayerView` (which walks a fixed
/// routine set-by-set), this is a grow-as-you-go logbook — add exercises and sets/attempts on the fly,
/// of any `SetKind` (reps & weight, timed, or climb attempts). Used for routineless sessions
/// (`routineID == nil`), e.g. an ad-hoc gym lifting session or a bouldering session where you don't
/// know the next climb. (dynamic-sessions D3/D5)
///
/// Kept separate from `WorkoutPlayerView` on purpose: the guided flow is device-verified and tightly
/// coupled to reps×weight + a fixed index walk; a list-based logbook is the right shape for "add as you
/// go" and avoids destabilizing it.
struct FreeformPlayerView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    let defaultUnit: WeightUnit
    /// Close + report whether to keep (finish / save & exit) or discard the session.
    let onClose: (_ saved: Bool) -> Void
    /// Dismiss without ending — the session stays active (background/minimize ask).
    let onMinimize: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app

    @State private var pickingLift = false
    @State private var logging: LogTarget?
    @State private var showingEnd = false

    private var unit: WeightUnit { defaultUnit }

    var body: some View {
        NavigationStack {
            List {
                hrSection
                ForEach(session.exercises) { ex in exerciseSection(ex) }
                addExerciseSection
                if session.completedSetCount > 0 { finishSection }
            }
            .navigationTitle(session.routineName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { timerHeader }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("End") { showingEnd = true }
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
        .confirmationDialog("End this workout?", isPresented: $showingEnd, titleVisibility: .visible) {
            Button("Save & exit") { finish(saved: true) }
            Button("Discard (don't save)", role: .destructive) { finish(saved: false) }
            Button("Keep going", role: .cancel) {}
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

    private var timerHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: isPaused ? "pause.fill" : "stopwatch")
                .foregroundStyle(isPaused ? .yellow : SnappetColor.workout)
            Text("Total").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(timerInterval: session.startedAt...Date.distantFuture, countsDown: false)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6).background(.bar)
        .accessibilityIdentifier("overallWorkoutTimer")
    }

    @ViewBuilder private var hrSection: some View {
        if let bpm = app.liveWorkout.latestHR {
            Section {
                Label("\(Int(bpm.rounded())) bpm · \(app.liveWorkout.displayName)", systemImage: "heart.fill")
                    .font(.subheadline).foregroundStyle(HeartRateZone.forBpm(bpm).color)
            }
        }
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
                Button { addExercise(kind: .climbAttempt, name: "Climbing") } label: {
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

    private var finishSection: some View {
        Section {
            Button { finish(saved: true) } label: {
                Text("Finish workout").font(.headline).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("freeform.finish")
        }
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
        app.liveActivity.update(WorkoutLiveSnapshot(
            startedAt: session.startedAt,
            hrBpm: app.liveWorkout.latestHR.map { Int($0.rounded()) },
            exerciseName: name,
            setProgress: "",
            paused: app.liveWorkout.isPaused))
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
    // duration
    @State private var minutes = ""
    @State private var seconds = ""
    // climb
    @State private var grade = ""
    @State private var status: KilterAscentStatus = .sent
    @State private var tries = 1

    init(kind: SetKind, unit: WeightUnit, onAdd: @escaping (SetLog) -> Void) {
        self.kind = kind
        self.unit = unit
        self.onAdd = onAdd
        _unitSel = State(initialValue: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .repsWeight:
                    TextField("Reps", text: $reps).keyboardType(.numberPad)
                        .accessibilityIdentifier("logset.reps")
                    HStack {
                        TextField("Weight", text: $weight).keyboardType(.decimalPad)
                            .accessibilityIdentifier("logset.weight")
                        Picker("Unit", selection: $unitSel) {
                            ForEach(WeightUnit.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 110).labelsHidden()
                    }
                case .duration:
                    HStack {
                        TextField("Min", text: $minutes).keyboardType(.numberPad)
                        Text(":").foregroundStyle(.secondary)
                        TextField("Sec", text: $seconds).keyboardType(.numberPad)
                    }
                    .accessibilityIdentifier("logset.duration")
                case .climbAttempt:
                    TextField("Grade (e.g. V4, 6c)", text: $grade)
                        .accessibilityIdentifier("logset.grade")
                    Picker("Outcome", selection: $status) {
                        ForEach(KilterAscentStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("Attempts: \(tries)", value: $tries, in: 1...50)
                }
            }
            .navigationTitle(kind.addLabel)
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
            return SetLog(climbGradeLabel: g.isEmpty ? nil : g,
                          climbStatusRaw: status.rawValue, climbAttempts: tries)
        }
    }
}
