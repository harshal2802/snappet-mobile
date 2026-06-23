import SwiftUI
import UIKit
import HighlightEngine

/// The **live timed-attempt FOCUS cover** (Quick Session redesign Phase 2): a dark, glass, full-screen
/// surface for timing ONE climbing attempt. It replaces the minimal `TimedAttemptSheet` — instead of a
/// half-sheet you drop into, this is an immersive single-purpose moment: a near-black base, a big
/// SF-Rounded hero timer that ticks off the wall clock, an optional live-HR chip, and a full-width STOP.
/// Tapping STOP freezes the timer and reveals an inline 2×2 outcome grid (thumb-nearest row = the
/// "close the climb" Send/Flash pair) that commits the attempt through the same `logAttempt` funnel the
/// rest of the player uses — stamping the climb grade + completedAt + haptic.
///
/// **Timing** is the `StopwatchViewModel(mode: .countUp)` driven DIRECTLY (not the packaged
/// `StopwatchView`, whose composite collapses under XCUITest): wall-clock-backed, so the digits stay
/// correct across backgrounding. We auto-`start()` on appear, `endTicking()` on disappear, and
/// `syncToWallClock()` when the scene re-activates.
///
/// **Never silently drop a captured effort:** dismissing (Peek / swipe-down) AFTER a Stop save-as-attempt;
/// dismissing BEFORE a Stop logs nothing. No milestone celebration here — Phase 3 owns that.
///
/// **Record a clip mid-attempt:** while the timer runs, a "Record a clip" button opens the in-app camera
/// (`RecordClipButton` → `VideoRecorder`) over this cover — the wall-clock timer keeps running underneath,
/// so finishing the recording drops the user back on the live attempt. Recordings are saved to Photos
/// immediately and queued in `recordedClips`; committing the outcome hands them up so they attach to the
/// attempt being logged.
struct TimedAttemptCover: View {
    let climbName: String
    let climbType: ClimbType
    let gradeLabel: String?
    /// 1-based ordinal of THIS attempt ("try N") — `attemptNumber == 1` reads "try 1" with no "of N".
    let attemptNumber: Int
    /// The same commit funnel the inline outcome strip uses: `logAttempt(toExerciseID:status:durationSec:)`,
    /// plus any clips recorded during the attempt (the owner attaches them to the just-logged attempt).
    let onCommit: (_ status: KilterAscentStatus, _ durationSec: Double?, _ clips: [RecordedClip]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var app

    /// The wall-clock stopwatch, driven directly (no packaged `StopwatchView`). `@State` so it lives for
    /// the cover's lifetime; auto-started on appear.
    @State private var vm = StopwatchViewModel(mode: .countUp)
    /// Seconds captured at Stop. `nil` while the timer is still running (pre-Stop). Once set, the cover is
    /// in its "outcome" phase and any dismissal must save-as-attempt rather than drop the effort.
    @State private var capturedSeconds: Double?
    /// Clips recorded with the in-app camera during this attempt, saved to Photos and queued to attach on commit.
    @State private var recordedClips: [RecordedClip] = []
    /// `true` while a just-recorded clip is still being saved to Photos. STOP is held until it lands so a
    /// record → immediate-STOP can't move to the outcome grid and commit before the clip is in `recordedClips`.
    @State private var savingClip = false

    private var isStopped: Bool { capturedSeconds != nil }

    var body: some View {
        ZStack {
            // A near-black FOCUS base so the hero timer is the only thing that reads.
            LinearGradient(
                colors: [Color.black, Color(red: 0.05, green: 0.05, blue: 0.08)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                topRow
                climbCard
                Spacer()
                heroTimer
                if let bpm = app.liveWorkout.latestHR { hrChip(bpm) }
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.start()
            // Keep the screen awake while timing an attempt off the wall — a sleeping screen mid-effort
            // hid the live timer (Phase-6 device note). Cheaply reverted on disappear. (Phase 7)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            vm.endTicking()
            // Never silently drop a captured effort: a dismissal after Stop (Peek / swipe-down) logs the
            // attempt with the captured duration AND any recorded clips. Cleared first so a subsequent
            // outcome-tap can't double-log / double-attach.
            if let captured = capturedSeconds {
                capturedSeconds = nil
                let clips = recordedClips
                recordedClips = []
                onCommit(.attempt, captured, clips)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.syncToWallClock() }
        }
    }

    // MARK: - Top row

    /// "⌄ Peek canvas" (dismiss without logging an outcome) + the "try N" label.
    private var topRow: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Peek canvas", systemImage: "chevron.down")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timedAttempt.cancel")

            Spacer()

            Text(tryLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("timedAttempt.try")
        }
    }

    /// "try 1" for the first attempt (no "of N"); the live counter is just "try N" — the cover times one
    /// attempt at a time and there's no fixed target count.
    private var tryLabel: String {
        attemptNumber <= 1 ? "try 1" : "try \(attemptNumber)"
    }

    // MARK: - Climb card

    /// A glass card identifying the climb being timed: type chip · name · grade pill.
    private var climbCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Label(climbType.label, systemImage: climbType.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
                Spacer(minLength: 8)
                gradePill
            }
            Text(climbName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var gradePill: some View {
        let isBoulder = !climbType.isRoute
        return Text(gradeLabel ?? "—")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(isBoulder ? SnappetColor.kilter : SnappetColor.budget, in: Capsule())
    }

    // MARK: - Hero timer

    /// The big SF-Rounded tabular elapsed readout. Rendered from `SetMeasure.formatDuration` (so the
    /// captured value matches the attempt row exactly, and a long attempt rolls to H:MM:SS). Greyed once
    /// stopped to read as a frozen capture.
    private var heroTimer: some View {
        Text(SetMeasure.formatDuration(vm.reading.elapsed))
            .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(isStopped ? .white.opacity(0.45) : .white)
            .contentTransition(.numericText())
            .accessibilityIdentifier("timedAttempt.timer")
    }

    /// The live-HR chip — shown ONLY when there's a bpm (omitted entirely, not "♥ --", when nil). bpm +
    /// the resolved zone dot + label, on a glass capsule.
    private func hrChip(_ bpm: Double) -> some View {
        let maxHR = app.userProfile.profile.resolvedMaxHR ?? HeartRateZone.defaultMaxHR
        let zone = HeartRateZone.forBpm(bpm, maxHR: maxHR)
        return HStack(spacing: 8) {
            Image(systemName: "heart.fill").foregroundStyle(zone.color)
            Text("\(Int(bpm.rounded())) bpm")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
            if zone != .none {
                Circle().fill(zone.color).frame(width: 8, height: 8)
                Text(zone.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("timedAttempt.hr")
    }

    // MARK: - Bottom controls

    /// Running → a full-width STOP. Stopped → the 2×2 outcome grid + "Save as attempt". Cross-fades
    /// between the two (the only animation honored under Reduce Motion).
    @ViewBuilder
    private var bottomControls: some View {
        if isStopped {
            outcomeGrid
                .transition(.opacity)
        } else {
            VStack(spacing: 12) {
                RecordClipButton(recordedClips: $recordedClips, savingClip: $savingClip,
                                 idPrefix: "timedAttempt", attachNoun: "attempt")
                stopButton
            }
            .transition(.opacity)
        }
    }

    private var stopButton: some View {
        Button {
            let captured = vm.stop()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                capturedSeconds = captured
            }
            Haptics.tap()
        } label: {
            Text("STOP")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .opacity(savingClip ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        // Hold STOP until any in-flight clip save finishes, so the clip is in `recordedClips` before the
        // outcome grid can commit it.
        .disabled(savingClip)
        .accessibilityIdentifier("timedAttempt.stop")
    }

    /// The 2×2 outcome grid — type-aware labels via `climbType.statusLabel`. The thumb-nearest BOTTOM row
    /// is the "close the climb" pair (Send / Flash); the TOP row is the in-progress pair (Fall / Project).
    /// Picking one commits `(status, capturedSeconds)` then dismisses. A "Save as attempt" sits below.
    private var outcomeGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                outcomeButton(.attempt)   // Fall / Fell
                outcomeButton(.project)   // Project
            }
            HStack(spacing: 12) {
                outcomeButton(.sent)      // Send / Redpoint
                outcomeButton(.flash)     // Flash / Onsight
            }
            Button {
                commit(.attempt)
            } label: {
                Text("Save as attempt")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timedAttempt.saveAsAttempt")
        }
    }

    private func outcomeButton(_ status: KilterAscentStatus) -> some View {
        let tint = outcomeTint(status)
        return Button {
            commit(status)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: outcomeSymbol(status))
                Text(climbType.statusLabel(status))
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timedAttempt.outcome.\(status.rawValue)")
    }

    private func outcomeSymbol(_ status: KilterAscentStatus) -> String {
        switch status {
        case .flash:   return "bolt.fill"
        case .sent:    return "checkmark.seal.fill"
        case .project: return "hourglass"
        case .attempt: return "arrow.uturn.down"
        }
    }

    private func outcomeTint(_ status: KilterAscentStatus) -> Color {
        switch status {
        case .flash:   return SnappetColor.kilter
        case .sent:    return SnappetColor.habits
        case .project: return SnappetColor.workout
        case .attempt: return Color(white: 0.3)
        }
    }

    /// Commit the chosen outcome with the captured duration + any recorded clips, then dismiss. Clears
    /// `capturedSeconds` and `recordedClips` first so the `onDisappear` save-as-attempt guard doesn't
    /// double-log / double-attach this same effort.
    private func commit(_ status: KilterAscentStatus) {
        let captured = capturedSeconds
        let clips = recordedClips
        capturedSeconds = nil
        recordedClips = []
        onCommit(status, captured, clips)
        dismiss()
    }
}
