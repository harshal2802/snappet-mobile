import SwiftUI
import HighlightEngine

/// The expandable **live-metrics & recovery** panel for the freeform player (issue #158 §E): tapping the
/// command-bar HR chip opens this sheet, which surfaces the live HR the app already collects but never
/// showed in-app — current bpm + zone, a recovery ring (the engine's already-computed `RecoveryReadiness`
/// fraction), running avg/max/redline + calories, a live HR trend, time-in-zone, and an optional inter-set
/// rest timer.
///
/// All HR math is the pure, unit-tested `LiveMetricsSummary` / `WorkoutHRStats` over the merged live
/// buffer (`LiveHRMerge.merge(watch, ble)`), refreshed on a throttled ~2 s cadence (a `TimelineView`).
/// The live buffer itself comes from the watch / BLE transports — **device-only**; on the simulator (no
/// HR source) the panel shows its no-source state. Reduce-Motion-safe; leaf-only a11y.
struct LiveMetricsPanel: View {
    let session: WorkoutSession

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Throttle the buffer rescan + recompute to ~2 s (the WorkoutLiveSnapshot.shouldPush cadence)
            // — a raw 1 Hz rescan of a long session buffer would be wasteful while the panel is open.
            TimelineView(.periodic(from: Date(), by: 2.0)) { _ in
                content
            }
            .navigationTitle("Live metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("freeform.metricsDone")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let profile = app.userProfile.profile
        let merged = LiveHRMerge.merge(app.liveWorkout.watch.samples, app.liveWorkout.ble.samples)
        let summary = LiveMetricsSummary.make(from: merged,
                                              currentBpm: app.liveWorkout.latestHR,
                                              maxHR: profile.resolvedMaxHR,
                                              restHR: profile.restingBound)
        ScrollView {
            VStack(spacing: 24) {
                if summary.hasData {
                    headline(summary)
                    statsGrid(summary, points: WorkoutHRStats.points(from: merged))
                    let points = WorkoutHRStats.points(from: merged)
                    if !points.isEmpty {
                        labelled("Heart rate") { HeartRateChart(series: points).frame(height: 160) }
                    }
                    if let stats = summary.stats, stats.totalSeconds > 0 {
                        labelled("Time in zone") { ZoneBar(stats: stats) }
                    }
                    labelled("Rest") { RestTimerView() }
                } else {
                    noSource
                }
            }
            .padding()
        }
    }

    // MARK: - Sections

    /// Current bpm + zone pill, beside the recovery ring (the engine's recovery fraction toward rest).
    private func headline(_ summary: LiveMetricsSummary) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill").foregroundStyle(summary.zone.color)
                    Text(summary.currentBpm.map(String.init) ?? "—")
                        .font(.system(size: 44, weight: .bold).monospacedDigit())
                    Text("bpm").font(.headline).foregroundStyle(.secondary)
                }
                Text(summary.zone.pillLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(summary.zone.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(summary.zone.color)
                if app.liveWorkout.isContactLost == true {
                    Label("Adjust strap", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            recoveryRing(summary.recovery)
        }
    }

    /// The recovery ring: fills toward "Recovered" as `RecoveryReadiness.fraction` → 1. Hidden when the
    /// readiness is `.unknown` (no profile bounds) — exactly like the existing nudge.
    @ViewBuilder private func recoveryRing(_ recovery: RecoveryReadiness) -> some View {
        if recovery.state != .unknown {
            let color: Color = recovery.state == .ready ? .green : .orange
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0, min(1, recovery.fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int((recovery.fraction * 100).rounded()))%")
                        .font(.headline.monospacedDigit())
                    Text(recovery.state == .ready ? "Ready" : "Resting")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery \(Int((recovery.fraction * 100).rounded())) percent, \(recovery.state == .ready ? "ready" : "resting")")
            .accessibilityIdentifier("freeform.recoveryRing")
        }
    }

    private func statsGrid(_ summary: LiveMetricsSummary, points: [HRPoint]) -> some View {
        let profile = app.userProfile.profile
        // Calories: measured energy for a watch session; the Keytel estimate for a BLE session with a
        // complete profile (never override the watch's real value — the finishWorkout gate).
        let kcal: Int? = {
            if app.liveWorkout.activeKind == .ble {
                return profile.estimatedKcal(forSeries: points, durationSec: session.duration)
                    .map { Int($0.rounded()) }
            }
            let measured = app.liveWorkout.energy
            return measured > 0 ? Int(measured.rounded()) : nil
        }()
        return HStack(spacing: 28) {
            stat(summary.avgBpm.map(String.init) ?? "—", "Avg")
            stat(summary.maxBpm.map(String.init) ?? "—", "Max")
            stat("\(Int((summary.redlineFraction * 100).rounded()))%", "Redline")
            if let kcal { stat("\(kcal)", "kcal") }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noSource: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No live heart rate").font(.headline)
            Text("Connect an Apple Watch or a heart-rate strap to see live zones, recovery, and calories.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }
}

/// An optional inter-set **rest timer** (§E): pick a preset → a wall-clock countdown (anchored on an
/// end-`Date`, so it stays correct across backgrounding) → a success haptic at zero. Opt-in for freeform
/// (no prescribed rest), Reduce-Motion-safe. A lightweight in-app analogue of the guided player's rest
/// countdown (no scheduled notification — that's for prescribed routine rest).
private struct RestTimerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var endDate: Date?
    @State private var total: Int = 0
    @State private var fireTask: Task<Void, Never>?

    private let presets = [60, 90, 120]

    var body: some View {
        Group {
            if let endDate {
                TimelineView(.periodic(from: Date(), by: 0.25)) { ctx in
                    let remaining = max(0, Int(endDate.timeIntervalSince(ctx.date).rounded(.up)))
                    countdown(remaining)
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(presets, id: \.self) { sec in
                        Button(SetMeasure.formatDuration(Double(sec))) { start(sec) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("freeform.rest.\(sec)")
                    }
                }
            }
        }
    }

    private func countdown(_ remaining: Int) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: total > 0 ? CGFloat(remaining) / CGFloat(total) : 0)
                    .stroke(SnappetColor.workout, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: remaining)
                Text(SetMeasure.formatDuration(Double(remaining)))
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 64, height: 64)
            Button("Stop") { stop() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("freeform.restStop")
        }
    }

    private func start(_ seconds: Int) {
        total = seconds
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        fireTask?.cancel()
        fireTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            Haptics.success()
            stop()
        }
    }

    private func stop() {
        fireTask?.cancel()
        fireTask = nil
        endDate = nil
        total = 0
    }
}
