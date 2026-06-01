import SwiftUI
import SwiftData
import UIKit

/// The live workout player: walks the user set-by-set through the session's exercises, logging
/// reps + weight for each set, running a rest timer between sets, and showing a summary when
/// done. Presented full-screen. Progress is saved to the session after every set, so a session
/// survives backgrounding and can be resumed. `onClose(saved:)` reports whether to keep the
/// session (finish / save & exit) or discard it.
struct WorkoutPlayerView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    let defaultUnit: WeightUnit
    let onClose: (_ saved: Bool) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
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
                case .exercise: exerciseScreen
                case .rest: restScreen
                case .done: doneScreen
                }
            }
            .navigationTitle(session.routineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Step back to fix a previously logged set.
                    if phase == .exercise && hasPrevious {
                        Button { goPrevious() } label: { Label("Previous set", systemImage: "chevron.left") }
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
        .onAppear { unit = defaultUnit; resumePosition() }
        .onDisappear { timerTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // Returning to foreground: recompute remaining from the wall clock immediately
            // instead of waiting up to 200ms for the next tick.
            if phase == .active, self.phase == .rest, let end = restEndDate {
                restRemaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
            }
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

    // MARK: - Exercise screen

    @ViewBuilder private var exerciseScreen: some View {
        if let ex = current {
            let exercise = resolver.exercise(id: ex.exerciseId)
            ScrollView {
                VStack(spacing: 20) {
                    liveMetricsDebugRow
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
                    .buttonStyle(.borderedProminent).tint(.orange)

                    Button(role: .destructive) { confirmingSkip = true } label: {
                        Label("Skip exercise", systemImage: "forward.end")
                    }
                    .font(.subheadline)

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

    /// Temporary debug readout proving the watch → phone HR relay is live (A1).
    /// The real overlay (HR zone + the two timers) lands in A4; this is just enough
    /// to confirm samples arrive end-to-end on a paired device. Shows the connection
    /// state when no sample has arrived yet so a missing watch is obvious.
    @ViewBuilder private var liveMetricsDebugRow: some View {
        let live = app.liveWorkout
        HStack(spacing: 8) {
            Image(systemName: "heart.fill").foregroundStyle(.pink)
            if let hr = live.latestHR {
                Text("\(Int(hr.rounded())) bpm")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text("· \(live.samples.count) samples")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(liveStatusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private var liveStatusText: String {
        switch app.liveWorkout.connectionState {
        case .unsupported: return "No watch metrics on this device"
        case .inactive: return "Watch connecting…"
        case .active: return app.liveWorkout.isWatchReachable
            ? "Watch ready — waiting for HR…" : "Open the workout on your watch"
        case .workoutRunning: return "Waiting for heart rate…"
        }
    }

    private func header(_ ex: SessionExercise) -> some View {
        VStack(spacing: 6) {
            Text("Exercise \(playedSoFar) of \(playableCount)")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                .font(.title2.bold()).multilineTextAlignment(.center)
        }
    }

    private func setPips(_ ex: SessionExercise) -> some View {
        HStack(spacing: 6) {
            ForEach(ex.sets.indices, id: \.self) { i in
                Circle()
                    .fill(ex.sets[i].completedAt != nil ? Color.orange
                          : (i == setIndex ? Color.orange.opacity(0.4) : Color(.systemGray4)))
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.top, 2)
    }

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
    }

    private func field(title: String, text: Binding<String>, keyboard: UIKeyboardType, suffix: String?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("0", text: text)
                    .keyboardType(keyboard).multilineTextAlignment(.center)
                    .font(.title3.weight(.semibold)).frame(width: 64)
                if let suffix { Text(suffix).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func instructions(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to").font(.headline)
            ForEach(Array(exercise.instructions.prefix(4).enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(idx + 1)").font(.caption.bold()).foregroundStyle(.orange)
                    Text(step).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rest screen

    private var restScreen: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("Rest").font(.title.bold())
            ZStack {
                Circle().stroke(Color(.systemGray5), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: restTotal > 0 ? CGFloat(restRemaining) / CGFloat(restTotal) : 0)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: restRemaining)
                Text(timeString(restRemaining)).font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
            }
            .frame(width: 220, height: 220)
            .background(flash ? Color.green.opacity(0.25) : .clear)
            .clipShape(Circle())

            if let next = nextSetLabel {
                Text(next).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { skipRest() } label: {
                Label("Skip rest", systemImage: "forward.fill").font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered).tint(.orange).padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Done screen

    private var doneScreen: some View {
        let volumeKg = WorkoutMath.sessionVolumeKg(session)
        return VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.orange)
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
            .buttonStyle(.borderedProminent).tint(.orange).padding(.horizontal)
        }
        .padding()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold().monospacedDigit())
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
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndDate = end
        phase = .rest
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

    @MainActor private func restFinished() async {
        restEndDate = nil
        Haptics.success()
        flash = true
        try? await Task.sleep(for: .milliseconds(350))
        flash = false
        advanceAfterRest()
    }

    private func skipRest() {
        timerTask?.cancel()
        restEndDate = nil
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

/// Thin haptics wrapper (UIKit is fine in the app target; only `HighlightEngine` is platform-free).
enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
