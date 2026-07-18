import SwiftUI
import SwiftData

/// Set detail — "climb detail for music" (wireframe frame 6). Everything comes from the linked
/// dance `WorkoutSession`(s): the hero stats and HR curve are `HRWindowSlicer` slices of the
/// session series under the SET's window (via the pure `FestivalSetStats`), the clips row is the
/// set's tag rows, and the reel CTA feeds the shared `ReelView` with a `festivalSet` source.
/// Pushed from a schedule row; NO stack of its own.
struct FestivalSetDetailView: View {
    let lineup: FestivalLineup
    let pack: FestivalPack
    let set: FestivalSet

    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app

    @Query private var attendance: [FestivalAttendance]
    @Query private var tags: [FestivalClipTag]

    @State private var sessions: [FestivalSessionSnapshot] = []
    /// The set's tagged clips joined to their `SessionMedia` rows, capture order.
    @State private var clipRows: [ClipRow] = []
    @State private var showingReview = false
    @State private var viewer: ViewerState?

    struct ClipRow: Identifiable {
        var mediaID: UUID
        var sessionID: UUID
        var localIdentifier: String
        var isVideo: Bool
        var offsetSec: Double
        var durationSec: Double?
        var aspect: Double?
        var isAuto: Bool
        var id: UUID { mediaID }
    }

    struct ViewerState: Identifiable {
        var clips: [MediaInput]
        var startIndex: Int
        var series: [HRPoint]
        var maxHR: Double
        var restHR: Double?
        var id: Int { startIndex }
    }

    init(lineup: FestivalLineup, pack: FestivalPack, set: FestivalSet) {
        self.lineup = lineup
        self.pack = pack
        self.set = set
        let packID = lineup.packID
        let setID = set.id
        _attendance = Query(filter: #Predicate<FestivalAttendance> {
            $0.packID == packID && $0.setID == setID
        })
        _tags = Query(filter: #Predicate<FestivalClipTag> {
            $0.packID == packID && $0.setID == setID
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statsRow
                hrCard
                clipsSection
                reelCTA
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .navigationTitle("Set")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: tags.count) { _, _ in Task { await load(refreshTags: false) } }
        .sheet(isPresented: $showingReview) {
            FestivalTagReviewView(lineup: lineup, pack: pack,
                                  initialDay: pack.day(containing: set.start)?.date)
                .presentationDetents([.large])
        }
        .navigationDestination(for: FestivalSetReelRoute.self) { _ in
            if let source = reelSource() {
                ReelView(source: source)
            } else {
                ContentUnavailableView("No clips to cut yet", systemImage: "sparkles.tv",
                                       description: Text("Tag a video to this set first."))
            }
        }
        .fullScreenCover(item: $viewer) { v in
            MediaBrowserView.clipsViewer(clips: v.clips, startIndex: v.startIndex,
                                         hrSeries: v.series, maxHR: v.maxHR, restHR: v.restHR,
                                         nameFor: { _ in "\(set.artist) · \(set.stage)" }, tile: nil)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(set.artist)
                .font(.title.bold())
                .accessibilityIdentifier("festival.set.artist")
            Text("\(set.stage) · "
                 + "\(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))–"
                 + "\(FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds))"
                 + " · \(lineup.name)")
                .font(.subheadline)
                .foregroundStyle(SnappetColor.textSecondary)
        }
    }

    private var statsRow: some View {
        let danced = FestivalSetStats.dancedSeconds(for: set.id, attendance: attendanceSnapshots)
        let slice = hrSlice
        let peak = FestivalSetStats.peak(of: slice)
        let avg = FestivalSetStats.average(of: slice)
        return HStack(spacing: 0) {
            stat(danced > 0 ? FestivalSetStats.dancedLabel(danced) : "—", "Danced")
            stat(peak.map { "\(Int($0.bpm.rounded()))" } ?? "—", "Peak HR",
                 tint: SnappetColor.perfHard)
            stat(avg.map { "\(Int($0.rounded()))" } ?? "—", "Avg HR")
            stat("\(resolvedTags.count)", "Clips")
        }
        .padding(.vertical, 12)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .accessibilityIdentifier("festival.set.stats")
    }

    private func stat(_ value: String, _ label: String, tint: Color = SnappetColor.ink) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// The set's HR curve with the peak-at-the-drop callout (frame 6) — the shared chart over the
    /// windowed slice, honest-empty when nothing was recorded under this set.
    @ViewBuilder private var hrCard: some View {
        let slice = hrSlice
        if slice.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Your heart rate")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SnappetColor.textSecondary)
                    Spacer()
                    if let callout = peakCallout {
                        Text(callout)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(SnappetColor.perfHard)
                            .accessibilityIdentifier("festival.set.peak")
                    }
                }
                HeartRateChart(series: slice)
                    .frame(height: 120)
                    .accessibilityIdentifier("festival.set.hrChart")
            }
            .padding(12)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md)
                .strokeBorder(SnappetColor.hairline))
        }
    }

    @ViewBuilder private var clipsSection: some View {
        HStack {
            Text("CLIPS FROM THIS SET")
                .font(.caption2.weight(.bold))
                .foregroundStyle(SnappetColor.textSecondary)
                .kerning(1)
            Spacer()
            Button("Review tags ›") { showingReview = true }
                .font(.caption.weight(.bold))
                .tint(SnappetColor.festival)
                .accessibilityIdentifier("festival.set.reviewTags")
        }
        if clipRows.isEmpty {
            Text("Nothing tagged here yet — anything filmed during this set tags itself.")
                .font(.caption)
                .foregroundStyle(SnappetColor.textSecondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(clipRows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            openViewer(at: index)
                        } label: {
                            clipCell(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .accessibilityIdentifier("festival.set.clips")
        }
    }

    private func clipCell(_ row: ClipRow) -> some View {
        ZStack(alignment: .topLeading) {
            FestivalClipThumb(localIdentifier: row.localIdentifier, isVideo: row.isVideo)
                .frame(width: 84, height: 106)
            if row.isAuto {
                Text("✦ AUTO")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(SnappetColor.festival.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
    }

    private var reelCTA: some View {
        NavigationLink(value: FestivalSetReelRoute()) {
            Label("Make a reel of this set", systemImage: "sparkles")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnappetColor.festival)
        .disabled(clipRows.isEmpty)
        .accessibilityIdentifier("festival.set.reel")
    }

    // MARK: - Data (thin edges over the pure stats)

    private var resolvedTags: [FestivalClipTag] { tags.filter(\.isResolved) }

    private var attendanceSnapshots: [FestivalAttendanceSnapshot] {
        attendance.map {
            FestivalAttendanceSnapshot(setID: $0.setID, sessionID: $0.sessionID,
                                       startedAt: $0.startedAt, endedAt: $0.endedAt)
        }
    }

    private var chartSession: FestivalSessionSnapshot? {
        FestivalSetStats.chartSession(for: set, sessions: sessions,
                                      attendance: attendanceSnapshots)
    }

    private var hrSlice: [HRPoint] {
        guard let session = chartSession else { return [] }
        return FestivalSetStats.hrSlice(for: set, session: session)
    }

    private var peakCallout: String? {
        guard let session = chartSession,
              let overlap = session.interval().intersection(with: set.window) else { return nil }
        return FestivalSetStats.peakCallout(slice: hrSlice, sliceStart: overlap.start,
                                            utcOffsetSeconds: pack.utcOffsetSeconds)
    }

    /// Run one tag pass (so the sheet's promise holds even if the user came straight here after a
    /// night), then join this set's tags to their media rows.
    private func load(refreshTags: Bool = true) async {
        if refreshTags {
            await FestivalTagSync.refresh(pack: pack, packID: lineup.packID, context: context,
                                          mediaService: app.sessionMedia)
        }
        // Sessions this set could chart from: the ones attendance/tags reference.
        let ids = Array(Set(attendance.map(\.sessionID)).union(tags.map(\.sessionID)))
        sessions = FestivalTagSync.fetchSessions(ids: ids, context: context).map {
            FestivalSessionSnapshot(id: $0.id, startedAt: $0.startedAt, endedAt: $0.completedAt,
                                    hrSeries: $0.hrSeries, maxHR: $0.maxHR, restHR: $0.restHR)
        }
        let sessionStart = Dictionary(sessions.map { ($0.id, $0.startedAt) },
                                      uniquingKeysWith: { a, _ in a })
        var rows: [ClipRow] = []
        for tag in resolvedTags {
            guard let media = mediaRow(id: tag.mediaID) else { continue }
            rows.append(ClipRow(mediaID: media.id, sessionID: media.sessionID,
                                localIdentifier: media.localIdentifier,
                                isVideo: media.kind == .video,
                                offsetSec: media.offsetSec, durationSec: media.durationSec,
                                aspect: media.aspectRatio,
                                isAuto: tag.source == .auto))
        }
        clipRows = rows.sorted {
            let a = sessionStart[$0.sessionID] ?? .distantPast
            let b = sessionStart[$1.sessionID] ?? .distantPast
            let at = a.addingTimeInterval($0.offsetSec), bt = b.addingTimeInterval($1.offsetSec)
            return at != bt ? at < bt : $0.mediaID.uuidString < $1.mediaID.uuidString
        }
    }

    private func mediaRow(id: UUID) -> SessionMedia? {
        (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.id == id })))?.first
    }

    private func openViewer(at index: Int) {
        guard let session = chartSession else { return }
        let clips = clipRows.map {
            MediaInput(id: $0.mediaID, kind: $0.isVideo ? "video" : "photo",
                       offsetSec: $0.offsetSec, durationSec: $0.durationSec,
                       exerciseId: nil, setIndex: nil, climbUUID: nil,
                       localIdentifier: $0.localIdentifier, aspect: $0.aspect)
        }
        viewer = ViewerState(clips: clips, startIndex: index,
                             series: session.hrSeries,
                             maxHR: session.maxHR ?? 190, restHR: session.restHR)
    }

    /// The shared-ReelView source for this set: the chart session's HR + the set's tagged clips
    /// FROM that session, the set window boosted, posting back as "Artist · Stage".
    private func reelSource() -> ReelSource? {
        guard let session = chartSession else { return nil }
        let clips = clipRows.filter { $0.sessionID == session.id }.map {
            SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier,
                                       isVideo: $0.isVideo,
                                       offsetSec: $0.offsetSec, durationSec: $0.durationSec)
        }
        guard !clips.isEmpty else { return nil }
        return ReelSource.festivalSet(set, session: session, clips: clips)
    }
}
