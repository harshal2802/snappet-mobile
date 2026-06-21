import SwiftUI

// MARK: - Recap Feed — session media browser (F3b)
//
// Instagram-style browser of ALL a session's clips, grouped By exercise / By session / All, each with a
// per-clip HR overlay (from FeedMedia.clipHR) + a name tag. The actual PHAsset thumbnail/video load and
// inline auto-play are the device-only edge (placeholder tiles render here so the structure is verifiable).

struct MediaBrowserView: View {
    let media: [MediaInput]
    let hrSeries: [HRPoint]
    let maxHR: Double
    let nameFor: (String) -> String     // group key (exerciseId / climbUUID) → label

    @Environment(\.dismiss) private var dismiss
    @State private var grouping: FeedMedia.Grouping = .byExercise
    @State private var viewer: MediaInput?

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Group", selection: $grouping) {
                    ForEach(FeedMedia.Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding()

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(FeedMedia.groups(media, by: grouping, nameFor: nameFor)) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(SnappetColor.ink)
                                Spacer()
                                Text("\(group.items.count) clip\(group.items.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(SnappetColor.textSecondary)
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(group.items) { item in
                                        tile(item).onTapGesture { viewer = item }
                                    }
                                }
                            }
                        }
                    }
                    if media.isEmpty {
                        ContentUnavailableView("No clips", systemImage: "video.slash",
                                               description: Text("Media shot during a session shows up here."))
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, SnappetSpacing.lg)
            }
            .background(SnappetColor.paper)
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewer) { item in
                MediaViewer(item: item, hr: clipHR(item), name: tagName(item))
            }
        }
        .accessibilityIdentifier("feed.media")
    }

    private func clipHR(_ m: MediaInput) -> MediaClipHR {
        FeedMedia.clipHR(offsetSec: m.offsetSec, durationSec: m.durationSec, hrSeries: hrSeries, maxHR: maxHR)
    }

    private func tagName(_ m: MediaInput) -> String {
        nameFor(m.exerciseId?.uuidString ?? m.climbUUID ?? "general")
    }

    private func tile(_ m: MediaInput) -> some View {
        let hr = clipHR(m)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [SnappetColor.kilter.opacity(0.5), .black], startPoint: .top, endPoint: .bottom))
                .frame(width: 104, height: 138)
                .overlay(Image(systemName: m.kind == "video" ? "play.circle.fill" : "photo")
                    .font(.title2).foregroundStyle(.white.opacity(0.9)))
                .overlay(alignment: .bottomLeading) {
                    Text(tagName(m)).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).padding(6)
                }
            if let peak = hr.peakBpm {
                Text("\(peak)").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(SnappetColor.performance(forZone: HeartRateZone(rawValue: hr.zoneRaw ?? 0) ?? .none), in: Capsule())
                    .padding(6)
            }
        }
    }
}

private struct MediaViewer: View {
    let item: MediaInput
    let hr: MediaClipHR
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [SnappetColor.kilter.opacity(0.35), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(alignment: .leading) {
                HStack {
                    Label(name, systemImage: item.kind == "video" ? "video.fill" : "photo.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                }
                Spacer()
                Image(systemName: item.kind == "video" ? "play.circle" : "photo")
                    .font(.system(size: 60)).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity)
                Text("Full media plays on device").font(.caption).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity)
                Spacer()
                if let peak = hr.peakBpm {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HEART RATE · THIS CLIP").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                        Text("\(peak) BPM").font(.system(size: 40, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        if let z = hr.zoneRaw, let zone = HeartRateZone(rawValue: z) {
                            Text(zone.pillLabel).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}
