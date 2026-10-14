import SwiftUI
import SwiftData

// MARK: - Activity progress P1 (prompt 178): every past clip of one activity
//
// The pager chip ("▶ 14 past clips") → a History sheet grouped by session, each clip stamped with its set
// and HR → a fullscreen viewer that pages across sessions. The join itself is the pure
// `ActivityMediaIndex`; this file is the thin SwiftData/Photos edge + the views.

extension ActivityMediaInput {
    static func from(_ m: SessionMedia) -> ActivityMediaInput {
        ActivityMediaInput(id: m.id, sessionID: m.sessionID, assignedExerciseID: m.assignedExerciseID,
                           assignedSetIndex: m.assignedSetIndex, kindRaw: m.kindRaw, offsetSec: m.offsetSec,
                           durationSec: m.durationSec, localIdentifier: m.localIdentifier,
                           isReel: m.isReel, isBaked: m.isBaked)
    }

    /// The feed's media value, so the viewer reuses `ClipMediaSurface` + `ClipHROverlay` unchanged.
    var mediaInput: MediaInput {
        MediaInput(id: id, kind: kindRaw, offsetSec: offsetSec, durationSec: durationSec,
                   exerciseId: assignedExerciseID, setIndex: assignedSetIndex, climbUUID: nil,
                   localIdentifier: localIdentifier, isBaked: isBaked)
    }
}

enum ActivityMediaStore {
    /// Every tagged media row as value snapshots — one fetch, so callers never hold `@Query` observation
    /// of the whole media table inside the (1 Hz re-rendering) live player.
    @MainActor
    static func snapshot(context: ModelContext) -> [ActivityMediaInput] {
        ((try? context.fetch(FetchDescriptor<SessionMedia>())) ?? []).map(ActivityMediaInput.from)
    }
}

/// What a sheet needs to open: which activity, and its display name.
struct ActivityClipsTarget: Identifiable, Hashable {
    let key: ActivityKey
    let title: String
    var id: ActivityKey { key }
}

// MARK: - Chip

/// "▶ 14 past clips" — shown on an exercise's page / row only when the activity has past clips.
struct PastClipsChip: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("\(count) past \(count == 1 ? "clip" : "clips")", systemImage: "play.rectangle.on.rectangle.fill")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(SnappetColor.workout)
                .background(SnappetColor.workout.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.pastClips")
    }
}

// MARK: - History sheet

/// Every past clip of one activity, grouped by session (newest first), each stamped with its set + HR.
struct ActivityClipsSheet: View {
    let target: ActivityClipsTarget
    let history: [WorkoutSession]
    /// The live / current session, whose own clips are shown elsewhere.
    var excludingSession: UUID? = nil
    let unit: WeightUnit

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ActivitySessionGroup] = []
    @State private var untagged = 0
    @State private var loaded = false
    @State private var viewing: CarouselViewerBox?

    private var distanceUnit: DistanceUnit { unit == .lb ? .mi : .km }
    private var allClips: [ActivityClip] { groups.flatMap(\.clips) }
    /// "4 clips · 4 sessions · 1 untagged" — the sheet at a glance (and a stable UI-test anchor, since
    /// the grid itself is lazy).
    private var summaryLine: String {
        let n = allClips.count
        var parts = ["\(n) \(n == 1 ? "clip" : "clips")",
                     "\(groups.count) \(groups.count == 1 ? "session" : "sessions")"]
        if untagged > 0 { parts.append("\(untagged) untagged") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !groups.isEmpty {
                        Text(summaryLine)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("activity.clips.summary")
                    }
                    ForEach(groups) { group in section(group) }
                    if untagged > 0 {
                        Label("\(untagged) more \(untagged == 1 ? "clip" : "clips") from these sessions \(untagged == 1 ? "isn't" : "aren't") tagged to an exercise. Tag them from the session's detail to see them here.",
                              systemImage: "tag")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("activity.clips.untagged")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .overlay {
                if loaded && groups.isEmpty {
                    ContentUnavailableView("No past clips", systemImage: "video.slash",
                                           description: Text("Film a set of \(target.title) and it shows up here next time."))
                }
            }
            .background(SnappetColor.paper)
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("activity.clips.done")
                }
            }
            .fullScreenCover(item: $viewing) { box in
                ActivityClipViewer(clips: allClips, startIndex: box.value,
                                   sessions: Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("activity.clips.sheet")
        .task {
            guard !loaded else { return }
            let media = ActivityMediaStore.snapshot(context: context)
            groups = ActivityMediaIndex.groups(for: target.key, history: history, media: media,
                                               excludingSession: excludingSession, unit: unit,
                                               distanceUnit: distanceUnit)
            untagged = ActivityMediaIndex.untaggedCount(for: target.key, history: history, media: media,
                                                        excludingSession: excludingSession)
            loaded = true
        }
    }

    private func section(_ group: ActivitySessionGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.subheadline.weight(.bold))
                if !group.title.isEmpty {
                    Text("· \(group.title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(group.clips.count) \(group.clips.count == 1 ? "clip" : "clips")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 10) {
                ForEach(group.clips) { clip in
                    Button { open(clip) } label: { ActivityClipTile(clip: clip) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func open(_ clip: ActivityClip) {
        if let idx = allClips.firstIndex(where: { $0.id == clip.id }) { viewing = CarouselViewerBox(value: idx) }
    }
}

/// One grid tile: the poster + the set stamp and HR under it.
struct ActivityClipTile: View {
    let clip: ActivityClip

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ClipThumbnail(localIdentifier: clip.media.localIdentifier, kind: clip.media.kindRaw,
                          size: CGSize(width: 76, height: 100), exactFrame: false)
            Text(clip.setSummary ?? "Whole exercise")
                .font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
            if let bpm = clip.avgBPM {
                Text("♥ \(bpm)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.clips.tile")
    }
}

// MARK: - Fullscreen viewer

/// A paged fullscreen player across sessions. Each clip draws its OWN session's HR overlay (the shared
/// `ClipHROverlay` mapping) and a caption with its date + set — so swiping is swiping through time.
struct ActivityClipViewer: View {
    let clips: [ActivityClip]
    let startIndex: Int
    let sessions: [UUID: WorkoutSession]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { i, clip in
                    ActivityClipPage(clip: clip, session: sessions[clip.sessionID], isActive: i == index)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            // On the pager, not the ZStack: a container identifier would flatten the close button's id.
            .accessibilityIdentifier("activity.clips.viewer")
            chrome
        }
        .onAppear {
            index = min(max(0, startIndex), max(0, clips.count - 1))
            ClipAudioSession.activate()
        }
        .onDisappear { ClipAudioSession.deactivate() }
    }

    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                if clips.indices.contains(index) { caption(clips[index]) }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .padding(10).background(.black.opacity(0.35), in: Circle())
                }
                .accessibilityIdentifier("activity.clips.close")
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 8)
    }

    private func caption(_ clip: ActivityClip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(clip.sessionDate, format: .dateTime.day().month(.abbreviated).year())
                .font(.headline).foregroundStyle(.white)
            HStack(spacing: 6) {
                if let s = clip.setSummary { Text(s) }
                if let bpm = clip.avgBPM { Text("♥ \(bpm)") }
                if clips.count > 1 { Text("\(index + 1)/\(clips.count)").foregroundStyle(.white.opacity(0.7)) }
            }
            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One page: the shared media surface + its session's HR scorebug + the transport bar for videos.
private struct ActivityClipPage: View {
    let clip: ActivityClip
    let session: WorkoutSession?
    let isActive: Bool

    @State private var fraction: Double = 1
    @State private var controller = ClipPlaybackController()

    private var input: MediaInput { clip.media.mediaInput }
    private var overlay: ClipHROverlay.Payload? {
        guard let session else { return nil }
        return ClipHROverlay.make(clip: input, hrSeries: session.hrSeries,
                                  maxHR: session.maxHR ?? HeartRateZone.defaultMaxHR, restHR: session.restHR)
    }

    var body: some View {
        let payload = overlay
        ZStack {
            ClipMediaSurface(clip: input, isActive: isActive, payload: payload, fraction: $fraction,
                             background: .black, controller: input.kind == "video" ? controller : nil)
                .ignoresSafeArea()
            if let payload {
                GeometryReader { geo in
                    HRTileView(tile: payload.tile, values: payload.values, fraction: fraction)
                        .frame(width: geo.size.width * payload.tile.width, height: geo.size.height * payload.tile.height)
                        // Lifted clear of the transport bar on a video (the scorebug sits at the bottom).
                        .position(x: geo.size.width * payload.tile.centerX,
                                  y: geo.size.height * payload.tile.centerY - (input.kind == "video" ? 84 : 0))
                }
                .allowsHitTesting(false)
            }
            if input.kind == "video", isActive {
                VStack { Spacer(); MediaTransportBar(controller: controller).padding(.bottom, 28) }
            }
        }
        .onAppear { fraction = ClipHROverlay.atEnd(for: payload) }
    }
}
