import SwiftUI

/// The "focus running" re-entry chip (issue #70): floats over the Apps tab while a
/// Pomodoro phase runs anywhere but the Pomodoro screen itself, and taps back into the
/// module. Ticks off the app-owned timer's `timeText` (the 1 s UI ticker), tinted by
/// phase like the in-app ring. Scoped to the Apps tab's NavigationStack until the
/// SuiteRouter hoist (#71) makes a shell-global surface possible.
struct PomodoroLiveChip: View {
    let timer: PomodoroTimer
    let open: () -> Void

    private var isFocus: Bool { timer.phase == .focus }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: isFocus ? "brain.head.profile" : "cup.and.saucer.fill")
                Text(timer.phase.title)
                Text(timer.timeText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .opacity(0.6)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isFocus ? SnappetColor.pomodoro : SnappetColor.habits, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pomodoro.liveChip")
        .accessibilityLabel("\(timer.phase.title) timer running, \(timer.timeText) remaining. Open Pomodoro.")
    }
}
