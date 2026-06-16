import SwiftUI

/// The cross-screen "session running" re-entry chip for a **planned** Kilter session — the fix for
/// "I hit play and there's no way back to it." Floats over the App Library `NavigationStack` while a
/// plan-backed session is live and the user is anywhere *outside* Kilter, and taps back to the
/// plan-home (the frozen list, with live progress). Modeled on `PomodoroLiveChip`
/// (`AppLibraryView`), tinted with the Kilter accent. It shows only for plan-backed sessions —
/// an ad-hoc session's re-entry stays the in-module session bar, since there's no plan to return to.
struct KilterLiveChip: View {
    /// When the live session started — drives the ticking elapsed clock.
    let startedAt: Date
    /// `(done, total)` picks for the running plan.
    let progress: (done: Int, total: Int)
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "figure.climbing")
                Text("\(progress.done)/\(progress.total)")
                    .monospacedDigit()
                // A 1 s ticker for the elapsed clock — same idiom as the Pomodoro chip's timeText.
                TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                    Text(Self.elapsed(from: startedAt, to: ctx.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .opacity(0.6)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(SnappetColor.moduleAccent("kilter"), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kilter.liveChip")
        .accessibilityLabel("Kilter session running, \(progress.done) of \(progress.total) climbs done. Open plan.")
    }

    /// `mm:ss` (or `h:mm:ss` past an hour) elapsed, clamped ≥ 0.
    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
