import SwiftUI

/// A reusable Start/Stop stopwatch — count **up** (press Start → it runs → Stop hands back the elapsed
/// seconds) or count **down** from an armed target (one success haptic fires at 0). Wall-clock-backed like
/// the workout rest timer: the displayed value is always recomputed from `Date` (correct across
/// backgrounding, no drift) via the pure `StopwatchTiming`; the ~200 ms task only refreshes the digits and
/// fires the at-zero haptic. Durations render through `SetMeasure.formatDuration`, and the count-down dial
/// reuses the rest timer's 220 pt arc + Reduce-Motion snap.
///
/// Shared by timed sets and per-climb attempts. **No callers yet** — wired into the timed-set log sheet
/// (PR 2) and the climb-attempt flow (PR 5). Verifiable on the simulator via the `#Preview` below.
/// (workout-with-timer PR 1, prompt 59)
@MainActor @Observable
final class StopwatchViewModel {
    private(set) var mode: StopwatchTiming.Mode
    /// Wall-clock anchor of the current run; `nil` when stopped or paused.
    private(set) var startedAt: Date?
    /// Seconds banked from previous run segments (everything before the current `startedAt`).
    private(set) var accumulated: TimeInterval = 0
    private(set) var isRunning = false
    /// Bumped by the refresh task to drive the SwiftUI digit update; the *value* always comes from
    /// `reading`, never from counting ticks.
    private(set) var now: Date = .now

    private var ticker: Task<Void, Never>?
    private var firedZeroHaptic = false

    init(mode: StopwatchTiming.Mode = .countUp) {
        self.mode = mode
    }

    /// Current snapshot (elapsed / remaining / reachedZero), recomputed from the wall clock.
    var reading: StopwatchTiming.Reading {
        StopwatchTiming.reading(startedAt: startedAt, accumulated: accumulated, now: now, mode: mode)
    }

    /// Set or clear a count-down target. `nil` → count up. Only allowed while stopped.
    func arm(target: TimeInterval?) {
        guard !isRunning else { return }
        mode = target.map { .countDown(targetSec: $0) } ?? .countUp
        firedZeroHaptic = false
        now = .now
    }

    /// Begin (or resume) running.
    func start() {
        guard !isRunning else { return }
        startedAt = .now
        now = .now
        isRunning = true
        runTicker()
    }

    /// Stop running and return the elapsed seconds captured (for the caller to persist).
    @discardableResult
    func stop() -> TimeInterval {
        if let started = startedAt {
            accumulated = StopwatchTiming.freeze(startedAt: started, accumulated: accumulated, now: .now)
        }
        startedAt = nil
        isRunning = false
        endTicking()
        now = .now
        return reading.elapsed
    }

    /// Clear back to zero (staying in the current mode).
    func reset() {
        endTicking()
        startedAt = nil
        accumulated = 0
        isRunning = false
        firedZeroHaptic = false
        now = .now
    }

    /// Recompute immediately — e.g. on returning to the foreground — without waiting for the next tick.
    func syncToWallClock() {
        guard isRunning else { return }
        now = .now
        checkZero()
    }

    /// Stop the refresh task (called on disappear). Leaves run state untouched.
    func endTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// Restart the refresh task after `endTicking()` when the run itself survived the disappearance —
    /// e.g. the hosting screen was behind a full-screen cover (or the finish summary) and came back.
    /// Without this the wall-clock math stays correct but the digits freeze at the last tick. Also
    /// fires the at-zero haptic if a count-down crossed its target while the screen was away.
    func resumeTicking() {
        guard isRunning, ticker == nil else { return }
        now = .now
        checkZero()
        runTicker()
    }

    private func runTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.now = .now
                self.checkZero()
            }
        }
    }

    /// Fire the success haptic exactly once, when a count-down first reaches its target.
    private func checkZero() {
        guard isRunning, reading.reachedZero, !firedZeroHaptic else { return }
        firedZeroHaptic = true
        Haptics.success()
    }
}

/// The stopwatch UI: a count-up digit readout or a count-down ring, plus a Start/Stop button.
struct StopwatchView: View {
    @State private var vm: StopwatchViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called with the captured elapsed seconds when the user taps Stop.
    private let onStop: (TimeInterval) -> Void
    /// Optional: notified when the run state flips (Start → true, Stop → false) so a host can gate
    /// actions that would tear down the timer mid-run (e.g. disable a mode toggle while running).
    private let onRunningChange: ((Bool) -> Void)?

    init(mode: StopwatchTiming.Mode = .countUp,
         onStop: @escaping (TimeInterval) -> Void = { _ in },
         onRunningChange: ((Bool) -> Void)? = nil) {
        _vm = State(initialValue: StopwatchViewModel(mode: mode))
        self.onStop = onStop
        self.onRunningChange = onRunningChange
    }

    var body: some View {
        VStack(spacing: 24) {
            dial
            controlButton
        }
        .onDisappear { vm.endTicking() }
        .onChange(of: vm.isRunning) { _, running in onRunningChange?(running) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.syncToWallClock() }
        }
    }

    @ViewBuilder private var dial: some View {
        switch vm.mode {
        case .countUp:
            Group {
                if vm.isRunning, vm.accumulated == 0, let started = vm.startedAt {
                    // Common case (no prior pause segment): let SwiftUI self-update off the wall clock —
                    // zero background CPU, exactly like the overall workout timer.
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                } else {
                    // Stopped, or resumed after a pause (banked time to add): drive from the recomputed
                    // reading so the total stays correct.
                    Text(SetMeasure.formatDuration(vm.reading.elapsed))
                }
            }
            .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())
            .accessibilityIdentifier("stopwatch.elapsed")

        case .countDown(let target):
            let remaining = vm.reading.remaining ?? target
            ZStack {
                Circle().stroke(Color(.systemGray5), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: target > 0 ? CGFloat(remaining / target) : 0)
                    .stroke(SnappetColor.workout, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // The drain is a quiet linear tick; under Reduce Motion it snaps (the rest timer's rule).
                    .animation(reduceMotion ? nil : .linear(duration: 0.2), value: remaining)
                Text(SetMeasure.formatDuration(remaining))
                    .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 220, height: 220)
            .accessibilityIdentifier("stopwatch.remaining")
        }
    }

    private var controlButton: some View {
        Button {
            if vm.isRunning {
                onStop(vm.stop())
            } else {
                vm.start()
            }
        } label: {
            Label(vm.isRunning ? "Stop" : "Start", systemImage: vm.isRunning ? "stop.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(vm.isRunning ? .red : SnappetColor.workout)
        .accessibilityIdentifier("stopwatch.toggle")
    }
}

#Preview("Count up") {
    StopwatchView(mode: .countUp) { elapsed in
        print("captured \(elapsed)s")
    }
    .padding()
}

#Preview("Count down 0:10") {
    StopwatchView(mode: .countDown(targetSec: 10)) { elapsed in
        print("held \(elapsed)s")
    }
    .padding()
}
