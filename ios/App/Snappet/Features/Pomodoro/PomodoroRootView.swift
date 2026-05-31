import SwiftUI
import SwiftData

/// Root screen for the Pomodoro mini-app. Pushed into the suite's NavigationStack, so
/// it sets only a `navigationTitle` (no nested NavigationStack).
struct PomodoroRootView: View {
    @Environment(SnappetCore.self) private var core
    @Environment(\.modelContext) private var modelContext

    // Sessions completed today, newest first, for the stats summary.
    @Query private var todaySessions: [PomodoroSession]

    @State private var timer = PomodoroTimer()
    @State private var showingSettings = false

    init() {
        let start = Calendar.current.startOfDay(for: .now)
        _todaySessions = Query(
            filter: #Predicate<PomodoroSession> { $0.completedAt >= start },
            sort: \.completedAt, order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                PhaseLabel(phase: timer.phase)
                TimerRing(progress: timer.progress, timeText: timer.timeText,
                          tint: timer.phase == .focus ? .red : .green)
                    .frame(width: 260, height: 260)
                controls
                TodayStats(count: focusCount, minutes: focusMinutes)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pomodoro")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Timer settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            PomodoroSettingsView(focusMinutes: $timer.focusMinutes,
                                 breakMinutes: $timer.breakMinutes,
                                 onChange: handleSettingsChange)
        }
        .onAppear {
            timer.onFocusCompleted = handleFocusCompleted
            core.log(module: "pomodoro", action: "open", summary: "Opened Pomodoro")
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 16) {
            Button(action: timer.reset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if timer.isRunning {
                Button(action: timer.pause) {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: timer.start) {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    // MARK: Derived stats

    private var focusCount: Int { todaySessions.count }
    private var focusMinutes: Int { todaySessions.reduce(0) { $0 + $1.minutes } }

    // MARK: Actions

    private func handleFocusCompleted(_ minutes: Int) {
        modelContext.insert(PomodoroSession(minutes: minutes, completedAt: .now))
        try? modelContext.save()
        core.log(module: "pomodoro", action: "session",
                 summary: "Focused \(minutes) min", metric: Double(minutes))
    }

    /// Reflect new lengths immediately when the timer is idle at the top of a phase.
    private func handleSettingsChange() {
        guard !timer.isRunning else { return }
        timer.reset()
    }
}

// MARK: - Subviews

private struct PhaseLabel: View {
    let phase: PomodoroPhase
    var body: some View {
        Label(phase.title, systemImage: phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(phase == .focus ? Color.red : Color.green)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct TimerRing: View {
    let progress: Double
    let timeText: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
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
            Image(systemName: systemImage).font(.title2).foregroundStyle(.red)
            Text(value).font(.title.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
