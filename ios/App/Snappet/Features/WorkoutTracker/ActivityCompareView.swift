import SwiftUI

/// **Then vs Now** (activity progress P3, prompt 180): two clips of the same activity side by side, played in
/// lockstep — sync start, play/pause both, ½× slow-mo — for a form check. The pair is chosen first in
/// `ActivityComparePicker`; either side can still be swapped here with its "Change" button. The footer reads the
/// gap between them (time, the two sets, the HR change).
struct ActivityCompareView: View {
    /// The activity's videos, oldest → newest (≥ 2).
    let clips: [ActivityClip]

    /// `left` / `right` are the picked pair ("then" / "now"); `nil` falls back to the first / latest video.
    init(clips: [ActivityClip], left: UUID? = nil, right: UUID? = nil) {
        self.clips = clips
        _leftID = State(initialValue: left)
        _rightID = State(initialValue: right)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var leftID: UUID?
    @State private var rightID: UUID?
    @State private var left = ClipPlaybackController()
    @State private var right = ClipPlaybackController()
    @State private var slow = false
    @State private var fractionL: Double = 1
    @State private var fractionR: Double = 1

    private var leftClip: ActivityClip? { clips.first { $0.id == leftID } ?? clips.first }
    private var rightClip: ActivityClip? { clips.first { $0.id == rightID } ?? clips.last }
    private var playing: Bool { left.isPlaying || right.isPlaying }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .padding(10).background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityIdentifier("activity.compare.close")
                Spacer()
                Text("Then vs Now").font(.headline).foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 6) {
                if let l = leftClip { side(l, controller: left, fraction: $fractionL, muted: true, select: { leftID = $0 }) }
                if let r = rightClip { side(r, controller: right, fraction: $fractionR, muted: false, select: { rightID = $0 }) }
            }
            .padding(.horizontal, 6)
            // `.contain` so the sides' Change buttons keep their own identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("activity.compare")

            controls
            if let l = leftClip, let r = rightClip { delta(l, r) }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(Color.black.ignoresSafeArea())
        .onAppear { ClipAudioSession.activate() }
        .onDisappear { ClipAudioSession.deactivate() }
    }

    private func side(_ clip: ActivityClip, controller: ClipPlaybackController, fraction: Binding<Double>,
                      muted: Bool, select: @escaping (UUID) -> Void) -> some View {
        ClipMediaSurface(clip: clip.media.mediaInput, isActive: true, payload: nil, fraction: fraction,
                         background: .black, muted: muted, controller: controller, fill: true)
            .id(clip.id)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.sessionDate, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption.weight(.bold))
                    if let s = clip.setSummary { Text(s).font(.caption2) }
                    if let bpm = clip.avgBPM { Text("♥ \(bpm)").font(.caption2) }
                }
                .foregroundStyle(.white).monospacedDigit()
                .padding(6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .padding(6)
            }
            // A visible way to swap this side — the old tap-the-date menu was undiscoverable.
            .overlay(alignment: .bottom) {
                Menu {
                    ForEach(clips) { c in
                        Button(ActivityProgressReel.caption(c)) { select(c.id) }
                    }
                } label: {
                    Label("Change", systemImage: "arrow.left.arrow.right")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.6), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                }
                .padding(.bottom, 10)
                .accessibilityIdentifier("activity.compare.change")
            }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            control(symbol: "backward.end.fill", label: "Sync start") {
                left.seek(toFraction: 0); right.seek(toFraction: 0)
                left.play(); right.play()
            }
            .accessibilityIdentifier("activity.compare.sync")
            control(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play") {
                if playing { left.pause(); right.pause() } else { left.play(); right.play() }
            }
            .accessibilityIdentifier("activity.compare.playpause")
            control(symbol: "tortoise.fill", label: slow ? "½×" : "1×") {
                slow.toggle()
                left.setRate(slow ? 0.5 : 1); right.setRate(slow ? 0.5 : 1)
            }
            .accessibilityIdentifier("activity.compare.speed")
        }
        .foregroundStyle(.white)
    }

    private func control(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(label).font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            .frame(minWidth: 60)
        }
        .buttonStyle(.plain)
    }

    private func delta(_ l: ActivityClip, _ r: ActivityClip) -> some View {
        let days = Calendar.current.dateComponents([.day], from: l.sessionDate, to: r.sessionDate).day ?? 0
        let span = days >= 60 ? "\(days / 30) months" : days >= 14 ? "\(days / 7) weeks" : "\(abs(days)) days"
        return HStack {
            Text(span)
            Spacer()
            Text("\(l.setSummary ?? "—") → \(r.setSummary ?? "—")").lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            if let a = l.avgBPM, let b = r.avgBPM {
                Text(b == a ? "same ♥" : "\(b > a ? "+" : "−")\(abs(b - a)) bpm")
                    .foregroundStyle(b < a ? SnappetColor.perfFresh : .white)
            }
        }
        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
        .padding(12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.compare.delta")
    }
}
