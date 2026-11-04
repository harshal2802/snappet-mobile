import SwiftUI
import SwiftData

/// The "On the floor" live sheet (wireframe frame 5) — the Kilter "On the Board" analog for a set.
/// Everything live comes from the workout spine: HR from `LiveMetricsCoordinator` (watch or BLE
/// band), the elapsed clock from the dance `WorkoutSession`, clips from the shared
/// `RecordClipButton` (saved to Photos + attached to the session, so prompt 03's matcher finds
/// them by timestamp). New here: the set countdown, the auto-tag promise, one-tap set switch.
struct FestivalLiveSheet: View {
    let pack: FestivalPack
    /// The open claim (an observable `@Model` — switching sets updates the sheet in place).
    let attendance: FestivalAttendance
    /// The dance session the claim rides; `nil` only if the row's session was deleted underneath us.
    let session: WorkoutSession?
    /// "Switch set ›" — the host opens "Where are you now?" once this sheet is gone (prompt 232).
    var onSwitch: () -> Void
    /// "End this set" — close the claim, keep the night on; the host asks "What's next?".
    var onEndSet: () -> Void
    var onEnd: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var recordedClips: [RecordedClip] = []
    @State private var savingClip = false
    /// Clips already attached to the session (by array index), so a new recording attaches once.
    @State private var attachedClipIDs: Set<UUID> = []

    private var currentSet: FestivalSet? { pack.setsByID[attendance.setID] }

    var body: some View {
        // Per-second cadence: the "Dancing 44:12" clock is the sheet's heartbeat. Scrollable so
        // every control stays hittable at the medium detent on smaller devices.
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                content(now: timeline.date)
            }
            .padding(.horizontal)
            .padding(.top, 18)
        }
        .presentationDragIndicator(.visible)
        .onChange(of: recordedClips) { _, clips in attach(clips) }
        .onChange(of: app.liveWorkout.latestHR) { _, bpm in
            // Keep the Lock Screen in step with the wrist without a per-second Activity update.
            app.liveActivity.update(hrBpm: bpm.map { Int($0.rounded()) },
                                    exerciseName: attendance.artist, setProgress: "")
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            nowHero(now: now)
            hrRow(now: now)
            RecordClipButton(recordedClips: $recordedClips, savingClip: $savingClip,
                             idPrefix: "festival.live", attachNoun: "set")
            autoTagPromise
            upNextRow(now: now)
            HStack(spacing: 8) {
                Button {
                    onEndSet()
                    dismiss()
                } label: {
                    Text("End this set")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SnappetColor.ink)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .pagerOutline()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("festival.live.endSet")
                Button(role: .destructive) {
                    onEnd()
                    dismiss()
                } label: {
                    Text("End the night")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SnappetColor.perfHard)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .overlay(Capsule().strokeBorder(SnappetColor.perfHard.opacity(0.6), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("festival.live.end")
            }
            Text("End this set to pick what's next — another set, a break, or walking. End the night when you're heading home.")
                .font(.caption2)
                .foregroundStyle(SnappetColor.textTertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pieces

    private func nowHero(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("ON THE FLOOR · \(attendance.stage.uppercased())")
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.festival)
                .kerning(1)
            Text(attendance.artist)
                .font(.title2.bold())
                .accessibilityIdentifier("festival.live.artist")
            if let set = currentSet {
                let range = "\(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))"
                    + " – \(FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds))"
                Text(now < set.end
                     ? "\(range) · \(FestivalSchedule.remainingLabel(set.end.timeIntervalSince(now)))"
                     : "\(range) · running late? Switch or end this set")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SnappetColor.festival.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
            .strokeBorder(SnappetColor.festival.opacity(0.4)))
    }

    private func hrRow(now: Date) -> some View {
        HStack(spacing: 12) {
            KilterHRPill(bpm: app.liveWorkout.latestHR)
            Spacer()
            if let session {
                Text("Dancing \(FestivalSchedule.elapsedLabel(since: session.startedAt, now: now))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SnappetColor.textSecondary)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var autoTagPromise: some View {
        Label {
            // Interpolated, not concatenated: `+` makes a String and drops the markdown (prompt 232).
            Text("Anything you film — here or straight from the Camera app — tags to **\(attendance.artist)** while this set plays.")
        } icon: {
            Image(systemName: "sparkles").foregroundStyle(SnappetColor.festival)
        }
        .font(.caption)
        .foregroundStyle(SnappetColor.textSecondary)
    }

    @ViewBuilder private func upNextRow(now: Date) -> some View {
        HStack(spacing: 6) {
            if let next = FestivalSchedule.upNext(in: pack, now: now) {
                Text("Up next: **\(next.artist)** · \(next.stage) · \(FestivalSchedule.timeLabel(next.start, offsetSeconds: pack.utcOffsetSeconds))")
                    .font(.caption)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer()
            Button("Switch set ›") {
                onSwitch()
                dismiss()
            }
            .font(.caption.weight(.bold))
            .tint(SnappetColor.festival)
            .accessibilityIdentifier("festival.live.switch")
        }
    }

    // MARK: - Clip attachment (the one funnel — SessionMediaService.candidate)

    /// Attach freshly-recorded clips to the dance session + its current set's entity, exactly like
    /// the pager attaches page-recorded clips. Idempotent per `RecordedClip.id`; the bytes live in
    /// Photos either way, so a missed attach still auto-tags by timestamp in prompt 03.
    private func attach(_ clips: [RecordedClip]) {
        guard let session else { return }
        let fresh = clips.filter { !attachedClipIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let name = "\(attendance.artist) · \(attendance.stage)"
        let exerciseID = session.exercises.last { $0.displayName == name }?.id
        let sid = session.id
        let existing = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        let byID = Dictionary(existing.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        for clip in fresh {
            attachedClipIDs.insert(clip.id)
            let c = SessionMediaService.candidate(for: clip, startedAt: session.startedAt)
            guard byID[c.localIdentifier] == nil else { continue }
            context.insert(SessionMedia(
                sessionID: sid, localIdentifier: c.localIdentifier, kind: c.kind,
                offsetSec: c.offsetSec, durationSec: c.durationSec, addedManually: true,
                assignedExerciseID: exerciseID, assignedSetIndex: nil,
                source: exerciseID == nil ? .general : .manual))
        }
        try? context.save()
    }
}
