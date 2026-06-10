import SwiftUI
import SwiftData

/// Root screen for the Pomodoro mini-app. Pushed into the suite's NavigationStack, so
/// it sets only a `navigationTitle` (no nested NavigationStack).
struct PomodoroRootView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Sessions over the last 7 days, newest first — drives the today stats and the chart.
    @Query private var recentSessions: [PomodoroSession]

    // Timer lengths persisted across launches; applied to the engine on appear / on change.
    @AppStorage("pomodoro.focusMinutes") private var focusSetting = 25
    @AppStorage("pomodoro.breakMinutes") private var breakSetting = 5

    @State private var showingSettings = false

    /// Convenience accessor — the timer is owned by AppModel so it survives navigating away and
    /// back (PomodoroRootView is a navigationDestination SwiftUI destroys on pop). Mirrors the
    /// `KilterRootView` → `app.kilterSessions` pattern (decisions.md 2026-06-07 / 2026-06-10).
    private var timer: PomodoroTimer { app.pomodoroTimer }

    init() {
        let start = Calendar.current.date(byAdding: .day, value: -6,
                                          to: Calendar.current.startOfDay(for: .now)) ?? .now
        _recentSessions = Query(
            filter: #Predicate<PomodoroSession> { $0.completedAt >= start },
            sort: \.completedAt, order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                PhaseLabel(phase: timer.phase)
                TimerRing(progress: timer.progress, timeText: timer.timeText,
                          tint: Self.tint(for: timer.phase), reduceMotion: reduceMotion)
                    .frame(width: 260, height: 260)
                    .accessibilityIdentifier("pomodoro.timeRemaining")
                    // Phase change (focus↔break) cross-fades the ring colour (issue #30 §5.4).
                    .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion),
                               value: timer.phase)
                controls
                TodayStats(count: focusCount, minutes: focusMinutes)
                PomodoroFocusChart(data: chartData)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pomodoro")
        .navigationDestination(for: PomodoroRoute.self) { _ in
            PomodoroHistoryView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: PomodoroRoute.history) {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("pomodoro.history")
                .accessibilityLabel("Session history")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityIdentifier("pomodoro.settings")
                .accessibilityLabel("Timer settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            PomodoroSettingsView(focusMinutes: $focusSetting,
                                 breakMinutes: $breakSetting,
                                 onChange: handleSettingsChange)
        }
        .onAppear {
            // Wire the focus-complete callback every time the view appears — the closure
            // captures `modelContext`, which is view-scoped, so re-wiring on each appear keeps
            // the reference current (the view is destroyed/recreated on pop/push but the timer
            // in AppModel persists and runs through those transitions).
            timer.onFocusCompleted = handleFocusCompleted
            // Wire services to the phase-started callback: schedule a local notification at
            // the phase's wall-clock deadline (so the user is reached when the phone is locked)
            // and start/update the Live Activity (Lock Screen + Dynamic Island countdown).
            timer.onPhaseStarted = { [app] phase, endDate in
                app.pomodoroNotifications.schedulePhaseComplete(for: phase, at: endDate)
                app.pomodoroLiveActivity.startOrUpdate(
                    phase: phase, phaseEndDate: endDate,
                    focusMinutes: app.pomodoroTimer.focusMinutes)
            }
            timer.applyDurations(focusMinutes: focusSetting, breakMinutes: breakSetting)
            app.pomodoroNotifications.requestAuthorization()
            core.log(module: "pomodoro", action: "open", summary: "Opened Pomodoro")
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Button(action: resetTimer) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("pomodoro.reset")

            if timer.isRunning {
                Button(action: pauseTimer) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pomodoro.pause")
            } else {
                Button(action: timer.start) {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pomodoro.start")
            }
        }
        .controlSize(.large)
    }

    /// Pulse accent for a phase: tomato while focusing, leaf-green on a break.
    private static func tint(for phase: PomodoroPhase) -> Color {
        phase == .focus ? SnappetColor.pomodoro : SnappetColor.habits
    }

    // MARK: Derived stats

    private var todaySessions: [PomodoroSession] {
        let start = Calendar.current.startOfDay(for: .now)
        return recentSessions.filter { $0.completedAt >= start }
    }
    private var focusCount: Int { todaySessions.count }
    private var focusMinutes: Int { todaySessions.reduce(0) { $0 + $1.minutes } }
    private var chartData: [DailyFocus] { PomodoroStats.last7Days(recentSessions) }

    // MARK: Actions

    private func handleFocusCompleted(_ minutes: Int) {
        modelContext.insert(PomodoroSession(minutes: minutes, completedAt: .now))
        try? modelContext.save()
        core.log(module: "pomodoro", action: "session",
                 summary: "Focused \(minutes) min", metric: Double(minutes))
    }

    /// Persisted lengths changed — push them into the engine and re-seed an idle timer so
    /// the new focus length shows immediately at the top of a phase.
    private func handleSettingsChange() {
        timer.applyDurations(focusMinutes: focusSetting, breakMinutes: breakSetting)
    }

    /// Pause the timer and cancel the pending phase-complete notification + update the Live
    /// Activity to show a "Paused" state.
    private func pauseTimer() {
        let phase = timer.phase
        timer.pause()
        app.pomodoroNotifications.clear()
        // Update the Live Activity as paused. `phaseEndDate` is nil after pause, so we pass
        // `Date.distantFuture` as a placeholder — the widget won't display it (paused: true
        // causes the widget to show "Paused" instead of the countdown).
        app.pomodoroLiveActivity.update(phase: phase, phaseEndDate: .distantFuture, paused: true)
    }

    /// Reset the timer, cancel the pending notification, and end the Live Activity.
    private func resetTimer() {
        timer.reset()
        app.pomodoroNotifications.clear()
        app.pomodoroLiveActivity.end()
    }
}

/// Navigation route for the Pomodoro module's deeper screens (pushed onto the suite stack).
enum PomodoroRoute: Hashable {
    case history
}

// MARK: - Subviews

private struct PhaseLabel: View {
    let phase: PomodoroPhase
    private var tint: Color { phase == .focus ? SnappetColor.pomodoro : SnappetColor.habits }
    var body: some View {
        Label(phase.title, systemImage: phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, SnappetSpacing.lg).padding(.vertical, SnappetSpacing.sm)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct TimerRing: View {
    let progress: Double
    let timeText: String
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Smooth, continuous ring progress; instant under Reduce Motion.
                .animation(reduceMotion ? nil : .linear(duration: 0.3), value: progress)
            Text(timeText)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

private struct TodayStats: View {
    let count: Int
    let minutes: Int

    var body: some View {
        if count == 0 {
            ContentUnavailableView("No focus sessions yet",
                systemImage: "checkmark.circle",
                description: Text("Complete a focus block to see your daily progress."))
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 12) {
                StatCard(value: "\(count)", label: count == 1 ? "Session" : "Sessions",
                         systemImage: "checkmark.circle.fill")
                StatCard(value: "\(minutes)", label: "Minutes",
                         systemImage: "clock.fill")
            }
        }
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(SnappetColor.pomodoro)
            Text(value).font(.title.weight(.bold)).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .snappetTile()
        .animation(.snappy, value: value)
    }
}
