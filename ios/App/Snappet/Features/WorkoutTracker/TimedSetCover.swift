import SwiftUI
import UIKit

/// The **"Time this set" FOCUS cover** (Workout-Type Parity Phase 3) — the strength/generic analogue of the
/// climb's `TimedAttemptCover`. It makes timing an *orthogonal* axis: a set keeps its reps × weight AND
/// gains a measured duration, so the logged row reads "8 × 60 kg · 0:42" (the combined `SetMeasure` row
/// added in Phase 0). A dark, glass, full-screen moment: an exercise card with editable reps/weight
/// steppers, a big count-up hero timer (wall-clock-backed, like the climb cover), an optional live-HR chip,
/// and a single full-width **STOP & LOG** that captures the duration and commits the set through the same
/// `appendLog` funnel.
///
/// Count-UP is the open-effort mentality (time-under-tension); a prescribed *target hold* (count-down) is a
/// later refinement. Dismissing before STOP logs nothing; STOP commits once and dismisses (no double-log).
struct TimedSetCover: View {
    let exerciseName: String
    /// Seeded from the card's quick-add (last set / prefill), editable here before/while timing.
    let initialReps: Int
    let initialWeight: Double
    let initialUnit: WeightUnit
    /// Commits the timed set: reps/weight (nil when zeroed → bodyweight / time-only) + the captured seconds.
    let onCommit: (_ reps: Int?, _ weight: Double?, _ unit: WeightUnit, _ durationSec: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app

    @State private var vm = StopwatchViewModel(mode: .countUp)
    @State private var reps: Int
    @State private var weight: Double
    @State private var unitSel: WeightUnit

    init(exerciseName: String, initialReps: Int, initialWeight: Double, initialUnit: WeightUnit,
         onCommit: @escaping (_ reps: Int?, _ weight: Double?, _ unit: WeightUnit, _ durationSec: Double) -> Void) {
        self.exerciseName = exerciseName
        self.initialReps = initialReps
        self.initialWeight = initialWeight
        self.initialUnit = initialUnit
        self.onCommit = onCommit
        _reps = State(initialValue: max(0, initialReps))
        _weight = State(initialValue: max(0, initialWeight))
        _unitSel = State(initialValue: initialUnit)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.05, green: 0.05, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                topRow
                exerciseCard
                Spacer()
                heroTimer
                if let bpm = app.liveWorkout.latestHR { hrChip(bpm) }
                Spacer()
                stopButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            vm.endTicking()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.syncToWallClock() }
        }
    }

    private var topRow: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Peek canvas", systemImage: "chevron.down")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timedSet.cancel")
            Spacer()
            Text("timed set").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
        }
    }

    /// A glass card: the exercise name + editable reps/weight steppers (the load this timed set carries).
    private var exerciseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(exerciseName)
                .font(.title3.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 10) {
                stepper(idBase: "timedSet.reps", label: "Reps", value: "\(reps)",
                        dec: { reps = max(0, reps - 1) }, inc: { reps = min(999, reps + 1) })
                stepper(idBase: "timedSet.weight", label: "Weight",
                        value: weight > 0 ? "\(SetMeasure.formatWeight(weight)) \(unitSel.display)" : "Body",
                        dec: { weight = max(0, weight - 2.5) }, inc: { weight = min(2000, weight + 2.5) })
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepper(idBase: String, label: String, value: String,
                         dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                Button(action: dec) { Image(systemName: "minus.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("\(idBase).minus").accessibilityLabel("Decrease \(label.lowercased())")
                Text(value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    .frame(minWidth: 64).accessibilityIdentifier(idBase)
                Button(action: inc) { Image(systemName: "plus.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("\(idBase).plus").accessibilityLabel("Increase \(label.lowercased())")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var heroTimer: some View {
        Text(SetMeasure.formatDuration(vm.reading.elapsed))
            .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .accessibilityIdentifier("timedSet.timer")
    }

    private func hrChip(_ bpm: Double) -> some View {
        let maxHR = app.userProfile.profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR
        let zone = HeartRateZone.forBpm(bpm, maxHR: maxHR)
        return HStack(spacing: 8) {
            Image(systemName: "heart.fill").foregroundStyle(zone.color)
            Text("\(Int(bpm.rounded())) bpm")
                .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
            if zone != .none {
                Circle().fill(zone.color).frame(width: 8, height: 8)
                Text(zone.label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("timedSet.hr")
    }

    /// STOP & LOG: capture the elapsed seconds, commit the set (reps/weight + duration), dismiss.
    private var stopButton: some View {
        Button {
            let captured = vm.stop()
            Haptics.tap()
            onCommit(reps > 0 ? reps : nil, weight > 0 ? weight : nil, unitSel, captured)
            dismiss()
        } label: {
            Text("STOP & LOG")
                .font(.title3.weight(.bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timedSet.stop")
    }
}
