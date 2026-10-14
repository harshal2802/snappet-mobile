import SwiftUI

/// Pick the two clips for **Then vs Now** (activity progress P3 follow-up): the activity's videos grouped by session,
/// newest first, with the first and latest pre-selected. Tapping a clip toggles it; picking a third replaces the
/// one picked longest ago. The older pick plays as "Then", the newer as "Now". Compare opens `ActivityCompareView`
/// over this sheet, so closing it comes back here to try another pair.
struct ActivityComparePicker: View {
    /// The activity's videos, oldest → newest (≥ 2).
    let clips: [ActivityClip]

    @Environment(\.dismiss) private var dismiss
    /// Picked clip ids in the order they were picked (max 2).
    @State private var picked: [UUID]
    @State private var comparing = false

    init(clips: [ActivityClip]) {
        self.clips = clips
        let defaults = [clips.first?.id, clips.count > 1 ? clips.last?.id : nil].compactMap { $0 }
        _picked = State(initialValue: defaults)
    }

    /// Newest session first, clips in capture order — the same reading order as the past-clips sheet.
    private var sessions: [(id: UUID, date: Date, clips: [ActivityClip])] {
        Dictionary(grouping: clips, by: \.sessionID)
            .map { (id: $0.key, date: $0.value[0].sessionDate, clips: $0.value.sorted { $0.media.offsetSec < $1.media.offsetSec }) }
            .sorted { $0.date > $1.date }
    }

    /// The picked pair in time order: (then, now).
    private var pair: (then: ActivityClip, now: ActivityClip)? {
        let chosen = clips.filter { picked.contains($0.id) }      // `clips` is oldest → newest
        guard chosen.count == 2 else { return nil }
        return (chosen[0], chosen[1])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("Pick two clips to compare. The older one plays as Then.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(sessions, id: \.id) { s in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.date, format: .dateTime.day().month(.abbreviated).year())
                                .font(.subheadline.weight(.bold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading,
                                      spacing: 10) {
                                ForEach(s.clips) { clip in
                                    Button { toggle(clip.id) } label: { tile(clip) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) {
                Button { comparing = true } label: {
                    Text(pair == nil ? "Pick \(2 - picked.count) more" : "Compare").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.brand).controlSize(.large)
                .disabled(pair == nil)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("activity.comparePicker.go")
            }
            .background(SnappetColor.paper)
            .navigationTitle("Then vs Now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("activity.comparePicker.cancel")
                }
            }
            .fullScreenCover(isPresented: $comparing) {
                if let pair { ActivityCompareView(clips: clips, left: pair.then.id, right: pair.now.id) }
            }
        }
        .presentationDetents([.large])
    }

    private func toggle(_ id: UUID) {
        if let i = picked.firstIndex(of: id) {
            picked.remove(at: i)
        } else {
            if picked.count == 2 { picked.removeFirst() }
            picked.append(id)
        }
    }

    private func tile(_ clip: ActivityClip) -> some View {
        let role: String? = pair.map { $0.then.id == clip.id ? "Then" : $0.now.id == clip.id ? "Now" : nil }
            ?? (picked.contains(clip.id) ? "✓" : nil)
        return ActivityClipTile(clip: clip)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(role == nil ? .clear : SnappetColor.brand, lineWidth: 3)
                    .frame(width: 76, height: 100)
            }
            .overlay(alignment: .topTrailing) {
                if let role {
                    Text(role).font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(SnappetColor.brand, in: Capsule())
                        .padding(4)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(role == nil ? [] : .isSelected)
            .accessibilityIdentifier("activity.comparePicker.clip")
    }
}
